# eBPF 기반 엣지 노드 선택 실험 시나리오 가이드

## 🎯 실험 시나리오 개요

실험에서는 **5가지 네트워크/시스템 교란 시나리오**를 통해 eBPF 기반 스케줄링의 효과를 검증합니다.

---

## 📊 **S1: 네트워크 지연 증가**
```bash
목적: RTT 증가가 스케줄링에 미치는 영향 분석
교란 내용: 20ms ± 5ms 추가 지연 (정규분포)
적용 명령: tc qdisc add dev eth0 root netem delay 20ms 5ms distribution normal
측정 지표: 
  - RTT p50/p99 변화
  - 응답시간 증가율
  - 스케줄링 선택 변화
```

**🔍 기대 효과:**
- 기본 스케줄러: 지연을 감지하지 못해 동일한 패턴으로 배치
- eBPF 스케줄러: RTT 증가를 감지해 더 나은 노드 선택

---

## 📊 **S2: 패킷 손실 유발**
```bash
목적: 네트워크 불안정성이 재전송률에 미치는 영향
교란 내용: 2% 패킷 손실
적용 명령: tc qdisc add dev eth0 root netem loss 2%
측정 지표:
  - TCP 재전송률 변화
  - 연결 안정성
  - 드롭 reason 분포
```

**🔍 기대 효과:**
- 재전송 증가로 인한 처리량 저하
- eBPF가 손실률 높은 노드 회피

---

## 📊 **S3: 대역폭 제한**
```bash
목적: 대역폭 제약 환경에서의 스케줄링 최적화
교란 내용: 50Mbps 대역폭 제한
적용 명령: tc qdisc add dev eth0 root tbf rate 50mbit burst 32kbit latency 400ms
측정 지표:
  - 처리량(QPS) 변화
  - 대기열 지연 증가
  - 노드별 부하 분산
```

**🔍 기대 효과:**
- 대역폭 포화로 인한 QPS 저하
- eBPF가 여유 대역폭 노드 선호

---

## 📊 **S4: CPU 압력 주입**
```bash
목적: CPU 부하가 스케줄링 성능에 미치는 영향
교란 내용: 2개 CPU 코어 100% 사용
적용 명령: stress-ng --cpu 2 --timeout 600s
측정 지표:
  - CPU 사용률 변화
  - Run queue latency 증가
  - 컨테이너 응답시간 지연
```

**🔍 기대 효과:**
- 높은 runqlat으로 응답시간 증가
- eBPF가 CPU 여유 노드 선택

---

## 📊 **S5: 노드 부분 장애**
```bash
목적: 간헐적 장애 상황에서의 복구력 테스트
교란 내용: 10초마다 10% 패킷 손실 on/off 반복
적용 명령: 
  while true; do 
    tc qdisc add dev eth0 root netem loss 10%
    sleep 10
    tc qdisc del dev eth0 root
    sleep 10
  done
측정 지표:
  - 장애 감지 속도
  - 스케줄링 적응성
  - MTTR (Mean Time To Recovery)
```

**🔍 기대 효과:**
- 간헐적 장애 패턴 감지
- eBPF가 실시간으로 노드 상태 추적

---

## 🔬 **스케줄링 모드 비교**

### 1️⃣ **Baseline (기본)**
```yaml
schedulerName: "default-scheduler"
```
- Kubernetes 기본 스케줄러
- CPU/메모리 기반 단순 배치
- 네트워크 상태 미고려

### 2️⃣ **NetworkAware (참조)**
```yaml
schedulerName: "network-aware-scheduler" 
```
- 토폴로지 인지 스케줄링
- 정적 네트워크 정보 활용
- 실시간 메트릭 미반영

### 3️⃣ **Proposed (제안)**
```yaml
schedulerName: "network-aware-scheduler"
```
- eBPF 실시간 텔레메트리 기반
- RTT/재전송/드롭/runqlat 종합 고려
- 동적 노드 점수 계산

---

## 📈 **실험 실행 명령어**

### 기본 실행:
```bash
./run-experiment.sh S1 baseline 100    # S1 시나리오, 기본 모드, 100 RPS
./run-experiment.sh S2 proposed 300    # S2 시나리오, 제안 모드, 300 RPS
./run-experiment.sh S3 networkaware 500 # S3 시나리오, 네트워크인지 모드, 500 RPS
```

### 고급 설정:
```bash
# 시나리오, 모드, RPS, 반복횟수, 지속시간, 워밍업, 쿨다운
./run-experiment.sh S4 baseline 200 10 900 600 300
```

### 전체 실험 자동화:
```bash
for scenario in S1 S2 S3 S4 S5; do
  for mode in baseline proposed; do
    for rps in 100 300 500; do
      ./run-experiment.sh $scenario $mode $rps
    done
  done
done
```

---

## 📊 **수집되는 주요 메트릭**

### eBPF 텔레메트리:
- `ebpf_rtt_p50_milliseconds` - RTT 50분위수
- `ebpf_rtt_p99_milliseconds` - RTT 99분위수  
- `ebpf_tcp_retrans_rate` - TCP 재전송률
- `ebpf_drop_rate` - 패킷 드롭률
- `ebpf_runqlat_p95_milliseconds` - 스케줄러 대기시간
- `ebpf_cpu_utilization` - CPU 사용률

### 스케줄러 성능:
- `scheduler_framework_score` - 노드별 점수
- `scheduler_e2e_scheduling_latency_seconds` - 스케줄링 지연

### 워크로드 성능:
- 응답시간 (p50/p99)
- 처리량 (QPS)
- 오류율
- CPU/백만메시지

---

## 🎯 **성공 판정 기준**

### 목표 개선율:
- **지연**: p99 응답시간 10% 이상 감소
- **신뢰성**: 오류/드롭률 20% 이상 감소  
- **효율성**: CPU/백만메시지 10% 이상 개선
- **안정성**: MTTR ≤ 3분
- **일관성**: 스코어-지연 상관계수 ≥ 0.6

### 통계적 유의성:
- n=5 회 반복 실험
- Mann-Whitney U 검정 (p < 0.05)
- Cliff's delta 효과크기 측정
- 다중비교 보정 (Holm 방법)

이제 각 시나리오가 무엇을 테스트하는지 명확하게 이해하실 수 있을 것입니다! 🚀
