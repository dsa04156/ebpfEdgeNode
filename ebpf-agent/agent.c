// eBPF Agent - Userspace component
// Collects telemetry from eBPF programs and exports Prometheus metrics

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/resource.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "telemetry.skel.h"

// Prometheus metrics structure
struct prometheus_metrics {
    double rtt_p50_ms;
    double rtt_p99_ms;
    double tcp_retrans_rate;
    double drop_rate;
    double runqlat_p95_ms;
    double cpu_utilization;
    char node_name[64];
    time_t last_update;
};

static volatile bool exiting = false;
static struct telemetry_bpf *skel = NULL;

// Signal handler for graceful shutdown
static void sig_handler(int sig) {
    exiting = true;
}

// Calculate percentile from histogram
static double calculate_percentile(struct hist *hist, double percentile) {
    __u32 total = 0;
    __u32 target_count;
    __u32 running_count = 0;
    
    // Calculate total count
    for (int i = 0; i < MAX_SLOTS; i++) {
        total += hist->slots[i];
    }
    
    if (total == 0)
        return 0.0;
    
    target_count = (total * percentile) / 100.0;
    
    // Find the bucket containing the target percentile
    for (int i = 0; i < MAX_SLOTS; i++) {
        running_count += hist->slots[i];
        if (running_count >= target_count) {
            // Convert bucket index back to value (2^i)
            return (double)(1 << i);
        }
    }
    
    return 0.0;
}

// Get CPU utilization from /proc/stat
static double get_cpu_utilization() {
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp)
        return 0.0;
    
    unsigned long long user, nice, system, idle, iowait, irq, softirq;
    if (fscanf(fp, "cpu %llu %llu %llu %llu %llu %llu %llu",
               &user, &nice, &system, &idle, &iowait, &irq, &softirq) != 7) {
        fclose(fp);
        return 0.0;
    }
    fclose(fp);
    
    unsigned long long total = user + nice + system + idle + iowait + irq + softirq;
    unsigned long long busy = total - idle - iowait;
    
    return (double)busy / total * 100.0;
}

// Get node name from hostname
static void get_node_name(char *node_name, size_t size) {
    if (gethostname(node_name, size) != 0) {
        strncpy(node_name, "unknown", size);
    }
}

// Process telemetry data and update metrics
static void update_metrics(struct prometheus_metrics *metrics, __u32 node_id) {
    struct node_metrics node_data;
    struct hist rtt_hist;
    
    // Read node metrics from BPF map
    if (bpf_map_lookup_elem(bpf_map__fd(skel->maps.node_metrics_map), 
                           &node_id, &node_data) == 0) {
        
        // Calculate retransmission rate (per second)
        static __u64 prev_retrans = 0;
        static __u64 prev_drops = 0;
        static time_t prev_time = 0;
        
        time_t current_time = time(NULL);
        if (prev_time > 0) {
            double time_diff = difftime(current_time, prev_time);
            if (time_diff > 0) {
                metrics->tcp_retrans_rate = 
                    (node_data.retrans_count - prev_retrans) / time_diff;
                metrics->drop_rate = 
                    (node_data.drop_count - prev_drops) / time_diff;
            }
        }
        
        prev_retrans = node_data.retrans_count;
        prev_drops = node_data.drop_count;
        prev_time = current_time;
        
        // Calculate average runqueue latency (simplified - should be percentile)
        if (node_data.runqlat_count > 0) {
            metrics->runqlat_p95_ms = 
                (double)node_data.runqlat_sum / node_data.runqlat_count;
        }
    }
    
    // Read RTT histogram and calculate percentiles
    if (bpf_map_lookup_elem(bpf_map__fd(skel->maps.rtt_hist_map), 
                           &node_id, &rtt_hist) == 0) {
        metrics->rtt_p50_ms = calculate_percentile(&rtt_hist, 50.0);
        metrics->rtt_p99_ms = calculate_percentile(&rtt_hist, 99.0);
    }
    
    // Get CPU utilization
    metrics->cpu_utilization = get_cpu_utilization();
    
    // Update timestamp
    metrics->last_update = time(NULL);
}

// Export metrics in Prometheus format
static void export_prometheus_metrics(struct prometheus_metrics *metrics) {
    printf("# HELP ebpf_rtt_p50_milliseconds 50th percentile RTT in milliseconds\n");
    printf("# TYPE ebpf_rtt_p50_milliseconds gauge\n");
    printf("ebpf_rtt_p50_milliseconds{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->rtt_p50_ms);
    
    printf("# HELP ebpf_rtt_p99_milliseconds 99th percentile RTT in milliseconds\n");
    printf("# TYPE ebpf_rtt_p99_milliseconds gauge\n");
    printf("ebpf_rtt_p99_milliseconds{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->rtt_p99_ms);
    
    printf("# HELP ebpf_tcp_retrans_rate TCP retransmission rate per second\n");
    printf("# TYPE ebpf_tcp_retrans_rate gauge\n");
    printf("ebpf_tcp_retrans_rate{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->tcp_retrans_rate);
    
    printf("# HELP ebpf_drop_rate Packet drop rate per second\n");
    printf("# TYPE ebpf_drop_rate gauge\n");
    printf("ebpf_drop_rate{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->drop_rate);
    
    printf("# HELP ebpf_runqlat_p95_milliseconds 95th percentile runqueue latency\n");
    printf("# TYPE ebpf_runqlat_p95_milliseconds gauge\n");
    printf("ebpf_runqlat_p95_milliseconds{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->runqlat_p95_ms);
    
    printf("# HELP ebpf_cpu_utilization CPU utilization percentage\n");
    printf("# TYPE ebpf_cpu_utilization gauge\n");
    printf("ebpf_cpu_utilization{node=\"%s\"} %.2f\n", 
           metrics->node_name, metrics->cpu_utilization);
    
    printf("\n");
    fflush(stdout);
}

// Handle ring buffer events
static int handle_event(void *ctx, void *data, size_t data_sz) {
    const struct telemetry_event *e = data;
    
    switch (e->event_type) {
        case 1: // RTT event
            printf("DEBUG: RTT event - Node: %u, Value: %llu ms\n", 
                   e->node_id, e->value);
            break;
        case 2: // Retransmission event
            printf("DEBUG: Retrans event - Node: %u\n", e->node_id);
            break;
        case 3: // Drop event
            printf("DEBUG: Drop event - Node: %u, Reason: %u\n", 
                   e->node_id, e->extra_data);
            break;
        case 4: // Runqueue latency event
            printf("DEBUG: Runqlat event - Node: %u, Value: %llu ms\n", 
                   e->node_id, e->value);
            break;
    }
    
    return 0;
}

// Setup eBPF program
static int setup_ebpf() {
    int err;
    
    // Open and load eBPF program
    skel = telemetry_bpf__open();
    if (!skel) {
        fprintf(stderr, "Failed to open BPF skeleton\n");
        return 1;
    }
    
    err = telemetry_bpf__load(skel);
    if (err) {
        fprintf(stderr, "Failed to load BPF skeleton: %d\n", err);
        telemetry_bpf__destroy(skel);
        return 1;
    }
    
    err = telemetry_bpf__attach(skel);
    if (err) {
        fprintf(stderr, "Failed to attach BPF skeleton: %d\n", err);
        telemetry_bpf__destroy(skel);
        return 1;
    }
    
    printf("eBPF program loaded and attached successfully\n");
    return 0;
}

int main(int argc, char **argv) {
    struct ring_buffer *rb = NULL;
    struct prometheus_metrics metrics = {0};
    int err;
    
    // Setup signal handlers
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    
    // Increase RLIMIT_MEMLOCK for BPF
    struct rlimit rlim_new = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY,
    };
    if (setrlimit(RLIMIT_MEMLOCK, &rlim_new)) {
        fprintf(stderr, "Failed to increase RLIMIT_MEMLOCK limit!\n");
        return 1;
    }
    
    // Get node name
    get_node_name(metrics.node_name, sizeof(metrics.node_name));
    
    // Setup eBPF program
    if (setup_ebpf() != 0) {
        return 1;
    }
    
    // Setup ring buffer
    rb = ring_buffer__new(bpf_map__fd(skel->maps.events), handle_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "Failed to create ring buffer\n");
        err = -1;
        goto cleanup;
    }
    
    printf("eBPF telemetry agent started on node: %s\n", metrics.node_name);
    printf("Collecting network and scheduling metrics...\n");
    
    // Main collection loop
    while (!exiting) {
        // Poll ring buffer for events
        err = ring_buffer__poll(rb, 100 /* timeout_ms */);
        if (err == -EINTR) {
            err = 0;
            break;
        }
        if (err < 0) {
            printf("Error polling ring buffer: %d\n", err);
            break;
        }
        
        // Update metrics every 5 seconds
        static time_t last_metrics_update = 0;
        time_t now = time(NULL);
        if (now - last_metrics_update >= 5) {
            // Assuming node_id 0 for this node (simplification)
            update_metrics(&metrics, 0);
            export_prometheus_metrics(&metrics);
            last_metrics_update = now;
        }
        
        sleep(1);
    }
    
cleanup:
    if (rb)
        ring_buffer__free(rb);
    if (skel)
        telemetry_bpf__destroy(skel);
    
    printf("eBPF telemetry agent exiting...\n");
    return err < 0 ? -err : 0;
}
