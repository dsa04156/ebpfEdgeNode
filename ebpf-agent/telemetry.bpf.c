// eBPF program for collecting network telemetry
// Collects RTT, retransmission, packet drops, and scheduling latency

#include <linux/types.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

// Maximum number of histogram buckets (log2 scale)
#define MAX_SLOTS 64
#define MAX_NODES 256

// Histogram structure for RTT measurements
struct hist {
    __u32 slots[MAX_SLOTS];
};

// Node metrics structure
struct node_metrics {
    __u64 rtt_sum;
    __u64 rtt_count;
    __u64 retrans_count;
    __u64 drop_count;
    __u64 runqlat_sum;
    __u64 runqlat_count;
    __u32 cpu_util;
    __u64 timestamp;
};

// Maps for storing metrics
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_NODES);
    __type(key, __u32);  // node_id
    __type(value, struct node_metrics);
} node_metrics_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_NODES);
    __type(key, __u32);  // node_id
    __type(value, struct hist);
} rtt_hist_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, __u32);  // drop_reason
    __type(value, __u64); // count
} drop_reason_map SEC(".maps");

// Ring buffer for sending events to userspace
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);
} events SEC(".maps");

// Event structure for userspace communication
struct telemetry_event {
    __u32 node_id;
    __u32 event_type;  // 1=RTT, 2=retrans, 3=drop, 4=runqlat
    __u64 value;
    __u64 timestamp;
    __u32 extra_data;  // For drop_reason, etc.
};

// Helper function to get histogram slot for log2 distribution
static __always_inline int value_to_slot(__u64 value) {
    if (value == 0)
        return 0;
    
    int slot = 0;
    while (value > 1 && slot < MAX_SLOTS - 1) {
        value >>= 1;
        slot++;
    }
    return slot;
}

// Helper to get current node ID (simplified - in practice use proper node identification)
static __always_inline __u32 get_node_id() {
    // For demo purposes, use a simple hash of the current CPU
    return bpf_get_smp_processor_id() % 8;  // Assuming max 8 nodes
}

// Tracepoint for TCP ACK to measure RTT
SEC("tracepoint/tcp/tcp_ack")
int trace_tcp_ack(struct trace_event_raw_tcp_ack *ctx) {
    struct tcp_sock *tp = (struct tcp_sock *)ctx->sk;
    if (!tp)
        return 0;
    
    __u32 srtt_us;
    if (bpf_core_read(&srtt_us, sizeof(srtt_us), &tp->srtt_us) != 0)
        return 0;
    
    // Convert from microseconds to milliseconds
    __u32 rtt_ms = srtt_us >> 3;  // srtt_us is in 1/8 microseconds
    rtt_ms /= 1000;
    
    __u32 node_id = get_node_id();
    
    // Update histogram
    struct hist *hist = bpf_map_lookup_elem(&rtt_hist_map, &node_id);
    if (!hist) {
        struct hist new_hist = {};
        bpf_map_update_elem(&rtt_hist_map, &node_id, &new_hist, BPF_ANY);
        hist = bpf_map_lookup_elem(&rtt_hist_map, &node_id);
        if (!hist)
            return 0;
    }
    
    int slot = value_to_slot(rtt_ms);
    if (slot >= 0 && slot < MAX_SLOTS)
        __sync_fetch_and_add(&hist->slots[slot], 1);
    
    // Update node metrics
    struct node_metrics *metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
    if (!metrics) {
        struct node_metrics new_metrics = {};
        bpf_map_update_elem(&node_metrics_map, &node_id, &new_metrics, BPF_ANY);
        metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
        if (!metrics)
            return 0;
    }
    
    __sync_fetch_and_add(&metrics->rtt_sum, rtt_ms);
    __sync_fetch_and_add(&metrics->rtt_count, 1);
    metrics->timestamp = bpf_ktime_get_ns();
    
    // Send event to userspace (sampling 1/100)
    if ((bpf_get_prandom_u32() % 100) == 0) {
        struct telemetry_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
        if (event) {
            event->node_id = node_id;
            event->event_type = 1;  // RTT event
            event->value = rtt_ms;
            event->timestamp = bpf_ktime_get_ns();
            event->extra_data = 0;
            bpf_ringbuf_submit(event, 0);
        }
    }
    
    return 0;
}

// Tracepoint for TCP retransmission
SEC("tracepoint/tcp/tcp_retransmit_skb")
int trace_tcp_retrans(struct trace_event_raw_tcp_retransmit_skb *ctx) {
    __u32 node_id = get_node_id();
    
    struct node_metrics *metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
    if (!metrics) {
        struct node_metrics new_metrics = {};
        bpf_map_update_elem(&node_metrics_map, &node_id, &new_metrics, BPF_ANY);
        metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
        if (!metrics)
            return 0;
    }
    
    __sync_fetch_and_add(&metrics->retrans_count, 1);
    metrics->timestamp = bpf_ktime_get_ns();
    
    // Send event to userspace
    struct telemetry_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
    if (event) {
        event->node_id = node_id;
        event->event_type = 2;  // Retrans event
        event->value = 1;
        event->timestamp = bpf_ktime_get_ns();
        event->extra_data = 0;
        bpf_ringbuf_submit(event, 0);
    }
    
    return 0;
}

// Tracepoint for packet drops
SEC("tracepoint/skb/kfree_skb")
int trace_skb_drop(struct trace_event_raw_kfree_skb *ctx) {
    __u32 reason = 0;
    
    // Try to read drop reason (available in newer kernels)
    if (bpf_core_field_exists(ctx->reason)) {
        bpf_core_read(&reason, sizeof(reason), &ctx->reason);
    }
    
    __u32 node_id = get_node_id();
    
    // Update drop reason counter
    __u64 *count = bpf_map_lookup_elem(&drop_reason_map, &reason);
    if (!count) {
        __u64 new_count = 1;
        bpf_map_update_elem(&drop_reason_map, &reason, &new_count, BPF_ANY);
    } else {
        __sync_fetch_and_add(count, 1);
    }
    
    // Update node metrics
    struct node_metrics *metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
    if (!metrics) {
        struct node_metrics new_metrics = {};
        bpf_map_update_elem(&node_metrics_map, &node_id, &new_metrics, BPF_ANY);
        metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
        if (!metrics)
            return 0;
    }
    
    __sync_fetch_and_add(&metrics->drop_count, 1);
    metrics->timestamp = bpf_ktime_get_ns();
    
    // Send event to userspace (sampling)
    if ((bpf_get_prandom_u32() % 10) == 0) {
        struct telemetry_event *event = bpf_ringbuf_reserve(&events, sizeof(*event), 0);
        if (event) {
            event->node_id = node_id;
            event->event_type = 3;  // Drop event
            event->value = 1;
            event->timestamp = bpf_ktime_get_ns();
            event->extra_data = reason;
            bpf_ringbuf_submit(event, 0);
        }
    }
    
    return 0;
}

// Tracepoint for scheduler wakeup (runqueue latency measurement)
SEC("tracepoint/sched/sched_wakeup")
int trace_sched_wakeup(struct trace_event_raw_sched_wakeup *ctx) {
    __u64 ts = bpf_ktime_get_ns();
    __u32 pid = ctx->pid;
    
    // Store wakeup timestamp (simplified - use proper PID map in production)
    bpf_map_update_elem(&node_metrics_map, &pid, &ts, BPF_ANY);
    
    return 0;
}

SEC("tracepoint/sched/sched_switch")
int trace_sched_switch(struct trace_event_raw_sched_switch *ctx) {
    __u64 ts = bpf_ktime_get_ns();
    __u32 next_pid = ctx->next_pid;
    
    // Calculate runqueue latency
    __u64 *wakeup_ts = bpf_map_lookup_elem(&node_metrics_map, &next_pid);
    if (!wakeup_ts)
        return 0;
    
    __u64 latency_ns = ts - *wakeup_ts;
    __u32 latency_ms = latency_ns / 1000000;  // Convert to milliseconds
    
    __u32 node_id = get_node_id();
    
    struct node_metrics *metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
    if (!metrics) {
        struct node_metrics new_metrics = {};
        bpf_map_update_elem(&node_metrics_map, &node_id, &new_metrics, BPF_ANY);
        metrics = bpf_map_lookup_elem(&node_metrics_map, &node_id);
        if (!metrics)
            return 0;
    }
    
    __sync_fetch_and_add(&metrics->runqlat_sum, latency_ms);
    __sync_fetch_and_add(&metrics->runqlat_count, 1);
    metrics->timestamp = ts;
    
    // Clean up wakeup timestamp
    bpf_map_delete_elem(&node_metrics_map, &next_pid);
    
    return 0;
}

char _license[] SEC("license") = "GPL";
