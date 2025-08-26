# eBPF-based Edge Node Selection for Network-Aware Kubernetes Scheduling

## 📋 목차

1. [실험 목표](#실험-목표)
2. [시스템 아키텍처](#시스템-아키텍처)
3. [설치 및 구성](#설치-및-구성)
4. [실험 실행](#실험-실행)
5. [결과 분석](#결과-분석)
6. [문제 해결](#문제-해결)
7. [참고 자료](#참고-자료)

## 🎯 실험 목표

eBPF 기반 텔레메트리를 사용한 "엣지 노드 선택(네트워크 인지 스케줄링)"이 기본 스케줄링 대비 다음 지표들을 개선하는지 검증:

### 주요 평가지표
- **지연**: p50/p99 response latency
- **신뢰성**: 오류/드롭률
- **처리량**: QPS (Queries Per Second)
- **효율성**: CPU/백만 메시지
- **안정성**: 스케줄 안정성(재스케줄 빈도)
- **운영성**: MTTR(스케줄러 롤백 시간), 도입/운영 난이도

## 🏗️ 시스템 아키텍처

### 컴포넌트 구조

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │   Test Pods     │  │   eBPF Agent    │  │  Scheduler   │ │
│  │   (Workloads)   │  │  (DaemonSet)    │  │  (Plugin)    │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │   Prometheus    │  │    Grafana      │  │   Cilium     │ │
│  │  (Monitoring)   │  │  (Dashboard)    │  │    (CNI)     │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### eBPF 텔레메트리 수집

1. **RTT 측정**: `tracepoint:tcp:tcp_ack`로 `tcp_sock->srtt_us` 샘플링
2. **재전송률**: `tracepoint:tcp:tcp_retransmit_skb` 카운트
3. **드롭 사유**: `tracepoint:skb:kfree_skb`에서 reason 맵 카운트
4. **스케줄러 대기시간**: `tracepoint:sched:sched_wakeup/sched_switch` 기반
5. **CPU 사용률**: `/proc/stat` 데이터와 cgroup 계측 결합

### 스코어링 알고리즘

```
score_raw = w1×norm(RTT_p99) + w2×norm(retrans_rate) + w3×norm(drop_rate_weighted) 
          + w4×norm(runqlat_p95) + w5×norm(cpu_util)

where:
- 가중치: RTT(0.3), Retrans(0.2), Drop(0.2), Runqlat(0.15), CPU(0.15)
- drop_rate_weighted: 드롭 reason별 가중치 적용
- 모든 메트릭은 [0,1] 범위로 정규화
```

## ⚙️ 설치 및 구성

### 시스템 요구사항

- **OS**: Ubuntu Server 22.04 LTS
- **커널**: ≥ 5.15 (권장: 5.17+)
- **하드웨어**: 
  - Control Plane: 4 vCPU / 8GB / 40GB
  - Worker Nodes: 4 vCPU / 8GB / 40GB × 3~7대
- **네트워크**: VM 간 통신 가능

### 1단계: 클러스터 구축

```bash
# 의존성 설치
sudo apt-get update
sudo apt-get install -y curl wget git make

# 프로젝트 클론
git clone <this-repository>
cd edgenode

# Kubernetes 클러스터 구축
cd infrastructure
chmod +x setup-cluster.sh
./setup-cluster.sh
```

### 2단계: 모니터링 스택 배포

```bash
cd ../monitoring
chmod +x deploy.sh
./deploy.sh
```

### 3단계: eBPF 에이전트 배포

```bash
cd ../ebpf-agent
make dev-setup        # 개발 도구 설치
make check-kernel     # 커널 호환성 확인
make smoke-test       # bpftrace로 스모크 테스트
make deploy          # DaemonSet 배포
```

### 4단계: 커스텀 스케줄러 배포

```bash
cd ../scheduler
make deps            # Go 의존성 설치
make deploy         # 스케줄러 배포
```

### 5단계: 테스트 워크로드 배포

```bash
cd ../workloads
chmod +x deploy.sh
./deploy.sh
```

## 🧪 실험 실행

### 기본 실험 실행

```bash
# 단일 실험 실행
make experiment SCENARIO=S1 MODE=proposed RPS=500

# 모든 시나리오 실행
./experiments/run-all-scenarios.sh

# 베이스라인 측정
make baseline
```

### 실험 시나리오

| 시나리오 | 설명 | 적용 방법 |
|---------|------|----------|
| **S1** | 네트워크 지연 증가 (20ms ± 5ms) | `tc qdisc add dev eth0 root netem delay 20ms 5ms` |
| **S2** | 패킷 손실/재전송 (2%) | `tc qdisc add dev eth0 root netem loss 2%` |
| **S3** | 대역폭 제한 (50Mbit) | `tc qdisc add dev eth0 root tbf rate 50mbit` |
| **S4** | CPU 압력 주입 | `stress-ng --cpu 4 --timeout 600s` |
| **S5** | 간헐적 네트워크 장애 | 10초 간격 on/off 스크립트 |

### 스케줄링 모드

1. **Baseline**: 기본 Kubernetes 스케줄러
2. **NetworkAware**: 참조 네트워크 인지 스케줄러 (선택사항)
3. **Proposed**: eBPF 기반 제안 방식

### 실험 매개변수

```bash
# 기본 설정
SCENARIO=S1          # 시나리오 (S1-S5)
MODE=proposed        # 스케줄링 모드
RPS=500             # 요청률 (100, 500, 1000)
REPLICAS=5          # 반복 횟수
DURATION=600        # 측정 시간 (초)
WARMUP=300         # 워밍업 시간 (초)
COOLDOWN=300       # 쿨다운 시간 (초)
```

### 고급 실험 실행

```bash
# 사용자 정의 실험
./experiments/run-experiment.sh S2 proposed 1000 3 900

# 배치 실험 (모든 조합)
./experiments/run-batch-experiments.sh

# 특정 워크로드만 테스트
./experiments/run-workload-specific.sh inference S1 proposed
```

## 📊 결과 분석

### 수집되는 메트릭

#### 애플리케이션 메트릭
- **지연시간**: p50, p99 response latency (ms)
- **처리량**: 실제 QPS
- **오류율**: HTTP 오류 비율 (%)
- **가용성**: 서비스 응답률

#### eBPF 텔레메트리
- **RTT**: `ebpf_rtt_p50_milliseconds`, `ebpf_rtt_p99_milliseconds`
- **재전송**: `ebpf_tcp_retrans_rate`
- **드롭**: `ebpf_drop_rate`, `ebpf_drop_reason_rate{reason}`
- **스케줄링**: `ebpf_runqlat_p95_milliseconds`
- **리소스**: `ebpf_cpu_utilization`

#### 스케줄러 메트릭
- **스코어**: `scheduler_framework_score{plugin,node}`
- **지연시간**: `scheduler_e2e_scheduling_latency_seconds`
- **처리량**: 초당 스케줄링 수

### 자동 분석

실험 완료 후 자동으로 생성되는 결과:

1. **`experiment_summary.csv`**: 모든 실험 결과 요약
2. **`statistical_analysis.csv`**: 통계적 유의성 분석
3. **`experiment_results.png`**: 시각화 차트
4. **개별 실험 데이터**: JSON, CSV 형태

### 수동 분석

```bash
# Prometheus 쿼리 예제
curl "http://localhost:30090/api/v1/query?query=ebpf_rtt_p99_milliseconds"

# Grafana 대시보드 접속
# http://localhost:30300 (admin/admin123)

# 결과 디렉터리 확인
ls /tmp/experiment-results/$(date +%Y%m%d-*)
```

### 성공 판정 기준

다음 조건 중 하나 이상 충족 시 성공:
- 모든 시나리오에서 p99 지연 **10% 이상 감소**
- 오류/드롭률 **20% 이상 감소**
- 동등 처리량에서 CPU/백만메시지 **10% 이상 개선**
- MTTR **≤ 3분** (스케줄러 롤백)
- 스코어-지연 상관관계 **ρ ≥ 0.6**

## 🚨 문제 해결

### 일반적인 문제

#### 1. eBPF 프로그램 로드 실패

```bash
# BTF 지원 확인
ls /sys/kernel/btf/vmlinux

# 권한 확인
kubectl logs -n observability -l app=ebpf-edge-agent

# 커널 모듈 확인
lsmod | grep bpf
```

#### 2. 메트릭 수집 안됨

```bash
# Prometheus targets 확인
curl http://localhost:30090/api/v1/targets

# ServiceMonitor 확인
kubectl get servicemonitor -A

# 에이전트 로그 확인
kubectl logs -n observability daemonset/ebpf-edge-agent
```

#### 3. 스케줄러 동작 안함

```bash
# 스케줄러 상태 확인
kubectl get pods -n kube-system -l app=network-aware-scheduler

# 스케줄러 로그 확인
kubectl logs -n kube-system -l app=network-aware-scheduler

# 설정 확인
kubectl get configmap network-aware-scheduler-config -n kube-system -o yaml
```

#### 4. 실험 데이터 수집 실패

```bash
# 노드 접근성 확인
kubectl get nodes -o wide

# 네트워크 조건 확인
ssh node1 "tc qdisc show dev eth0"

# 로드 테스트 도구 설치 확인
which fortio
```

### 로그 위치

```bash
# eBPF 에이전트 로그
kubectl logs -n observability daemonset/ebpf-edge-agent -f

# 스케줄러 로그
kubectl logs -n kube-system -l app=network-aware-scheduler -f

# 실험 로그
tail -f /tmp/experiment-results/latest/experiment.log

# 시스템 로그
journalctl -u kubelet -f
```

### 롤백 절차 (MTTR 측정)

```bash
# 빠른 롤백 (자동 시간 측정)
cd scheduler
make rollback

# 수동 롤백
kubectl patch deployment kube-scheduler -n kube-system \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"kube-scheduler","image":"k8s.gcr.io/kube-scheduler:v1.28.4"}]}}}}'

# 완전 정리
cd scripts
./cleanup.sh --all
```

## 🧹 정리

### 부분 정리

```bash
# 특정 컴포넌트만 정리
./scripts/cleanup.sh --workloads    # 워크로드만
./scripts/cleanup.sh --monitoring   # 모니터링만
./scripts/cleanup.sh --ebpf         # eBPF 에이전트만
./scripts/cleanup.sh --scheduler    # 스케줄러만
./scripts/cleanup.sh --network      # 네트워크 조건만
```

### 전체 정리

```bash
# 모든 실험 컴포넌트 정리
./scripts/cleanup.sh --all

# 상태 확인
./scripts/cleanup.sh --status

# 완전 초기화 (위험)
./scripts/cleanup.sh --destructive
```

## 📚 참고 자료

### 기술 문서

- [eBPF Documentation](https://ebpf.io/what-is-ebpf/)
- [Kubernetes Scheduler Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [Cilium eBPF Guide](https://docs.cilium.io/en/latest/bpf/)
- [Prometheus Monitoring](https://prometheus.io/docs/)

### 관련 논문

- "eBPF for Network Function Virtualization" (NSDI 2021)
- "Network-Aware Scheduling in Kubernetes" (SIGCOMM 2020)
- "Performance Isolation in Multi-tenant Edge Computing" (EuroSys 2022)

### 추가 도구

- [bpftrace](https://github.com/iovisor/bpftrace) - eBPF 스크립팅
- [BCC](https://github.com/iovisor/bcc) - eBPF 도구 모음
- [Fortio](https://github.com/fortio/fortio) - 로드 테스팅
- [Grafana](https://grafana.com/docs/) - 시각화

## 🤝 기여하기

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다. 자세한 내용은 `LICENSE` 파일을 참조하세요.

## 📞 지원

문제가 발생하거나 질문이 있으시면:

1. GitHub Issues에 문제 보고
2. 문서 확인: `/docs` 디렉터리
3. 로그 분석: 위의 문제 해결 섹션 참조
4. 커뮤니티 지원: [eBPF Slack](https://ebpf.io/slack)
