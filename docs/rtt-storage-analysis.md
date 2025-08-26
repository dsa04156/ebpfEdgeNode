# RTT 데이터 저장 구조 분석

## 🔄 **RTT 데이터 플로우**

### 1️⃣ **커널 수집 (eBPF)**
```c
// tracepoint: tcp/tcp_ack
SEC("tracepoint/tcp/tcp_ack")
int trace_tcp_ack(struct trace_event_raw_tcp_ack *ctx) {
    struct tcp_sock *tp = (struct tcp_sock *)ctx->sk;
    
    // 1. TCP 소켓에서 srtt_us 읽기
    __u32 srtt_us;
    bpf_core_read(&srtt_us, sizeof(srtt_us), &tp->srtt_us);
    
    // 2. 마이크로초 → 밀리초 변환
    __u32 rtt_ms = srtt_us >> 3;  // srtt_us는 1/8 마이크로초 단위
    rtt_ms /= 1000;
    
    // 3. 히스토그램 업데이트
    int slot = value_to_slot(rtt_ms);  // log2 버킷
    hist->slots[slot]++;
    
    // 4. 노드 메트릭 업데이트
    metrics->rtt_sum += rtt_ms;
    metrics->rtt_count++;
}
```

### 2️⃣ **eBPF 맵 저장소**

#### A. 히스토그램 맵 (`rtt_hist_map`)
```c
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_NODES);  // 256개 노드
    __type(key, __u32);              // node_id
    __type(value, struct hist);      // 히스토그램 구조체
} rtt_hist_map;

struct hist {
    __u32 slots[MAX_SLOTS];  // 64개 버킷 (log2 분포)
};
```

**저장 방식:**
- 키: `node_id` (0, 1, 2, ...)
- 값: 64개 슬롯의 히스토그램
- 버킷: `[0-1ms], [1-2ms], [2-4ms], [4-8ms], ...`

#### B. 노드 메트릭 맵 (`node_metrics_map`)
```c
struct node_metrics {
    __u64 rtt_sum;     // RTT 누적 합계
    __u64 rtt_count;   // RTT 측정 횟수
    __u64 retrans_count;
    __u64 drop_count;
    __u64 runqlat_sum;
    __u64 runqlat_count;
    __u32 cpu_util;
    __u64 timestamp;
};
```

### 3️⃣ **이벤트 스트림 (Ring Buffer)**
```c
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);  // 16MB 링버퍼
} events;

struct telemetry_event {
    __u32 node_id;
    __u32 event_type;  // 1=RTT, 2=retrans, 3=drop, 4=runqlat
    __u64 value;       // RTT 값 (밀리초)
    __u64 timestamp;   // 나노초 타임스탬프
    __u32 extra_data;
};
```

**샘플링:** 1/100 확률로 이벤트 전송 (성능 최적화)

### 4️⃣ **유저스페이스 처리 (agent.c)**

#### A. 주기적 메트릭 업데이트 (5초마다)
```c
static void update_metrics(struct prometheus_metrics *metrics, __u32 node_id) {
    // 1. BPF 맵에서 히스토그램 읽기
    bpf_map_lookup_elem(skel->maps.rtt_hist_map, &node_id, &rtt_hist);
    
    // 2. 백분위수 계산
    metrics->rtt_p50_ms = calculate_percentile(&rtt_hist, 50.0);
    metrics->rtt_p99_ms = calculate_percentile(&rtt_hist, 99.0);
    
    // 3. Prometheus 메트릭 출력
    export_prometheus_metrics(metrics);
}
```

#### B. Prometheus 메트릭 출력
```prometheus
# HELP ebpf_rtt_p50_milliseconds 50th percentile RTT in milliseconds
# TYPE ebpf_rtt_p50_milliseconds gauge
ebpf_rtt_p50_milliseconds{node="cluster1"} 25.50

# HELP ebpf_rtt_p99_milliseconds 99th percentile RTT in milliseconds  
# TYPE ebpf_rtt_p99_milliseconds gauge
ebpf_rtt_p99_milliseconds{node="cluster1"} 187.25
```

## 📍 **실제 저장 위치**

### 커널 공간:
```bash
/sys/fs/bpf/           # BPF 파일시스템 마운트
├── rtt_hist_map       # 히스토그램 맵
├── node_metrics_map   # 노드 메트릭 맵
└── events             # 링버퍼
```

### 유저 공간:
```bash
# 1. 메모리 내 구조체
struct prometheus_metrics metrics = {
    .rtt_p50_ms = 25.50,
    .rtt_p99_ms = 187.25,
    .node_name = "cluster1",
    .last_update = 1693123456
};

# 2. stdout 출력 (Prometheus 스크랩 대상)
ebpf_rtt_p50_milliseconds{node="cluster1"} 25.50
ebpf_rtt_p99_milliseconds{node="cluster1"} 187.25

# 3. 디버그 로그
DEBUG: RTT event - Node: 0, Value: 28 ms
```

### Prometheus 저장:
```bash
# TSDB 저장 경로 (시계열 DB)
/prometheus/data/
├── 01HX...            # 블록 디렉토리
│   ├── chunks/        # 압축된 샘플 데이터
│   ├── index          # 인덱스 파일
│   └── meta.json      # 메타데이터
```

## 🔄 **데이터 접근 방법**

### 1. BPF 맵 직접 접근:
```bash
bpftool map dump name rtt_hist_map
bpftool map lookup name node_metrics_map key 0
```

### 2. Prometheus 쿼리:
```promql
ebpf_rtt_p99_milliseconds
rate(ebpf_rtt_p99_milliseconds[5m])
histogram_quantile(0.95, ebpf_rtt_p99_milliseconds)
```

### 3. 실시간 이벤트:
```bash
# Ring buffer 이벤트 모니터링
cat /sys/kernel/debug/tracing/trace_pipe | grep "RTT event"
```

## 📊 **성능 특성**

- **수집 빈도**: 모든 TCP ACK 패킷마다
- **저장 오버헤드**: 히스토그램 64슬롯 × 4바이트 = 256바이트/노드
- **이벤트 샘플링**: 1% (100개 중 1개만 링버퍼 전송)
- **메트릭 업데이트**: 5초 주기
- **메모리 사용량**: ~16MB 링버퍼 + ~64KB 맵

이렇게 RTT 데이터는 **커널 → eBPF 맵 → 유저스페이스 → Prometheus**의 경로로 저장되고 전달됩니다! 🚀
