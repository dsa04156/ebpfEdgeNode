# 실험 결과 문제점 진단 및 개선 방안

## 🚨 **주요 문제점 발견**

### ❌ **1. eBPF 에이전트 실패**
```
현재 상태:
- cluster1: CrashLoopBackOff (7회 재시작)
- cluster2: Running (하지만 불안정)  
- cluster3: CrashLoopBackOff (7회 재시작)

문제: 실제 eBPF 프로그램이 로드되지 않음
원인: 컨테이너 내에서 placeholder 스크립트만 실행 중
```

### ❌ **2. RTT 측정 없음**
```
로그 출력:
"eBPF metrics collection simulated"
"Metrics endpoint not ready"

문제: 실제 RTT 데이터 수집 안됨
원인: eBPF 프로그램 미컴파일/미로드
```

### ❌ **3. 스케줄링 불균형 심각**
```
노드 분산:
- cluster1: 0개 (0%) ← 완전 회피
- cluster2: 8개 (67%) ← 과집중  
- cluster3: 4개 (33%) ← 부족
- Pending: 3개 (20%) ← 스케줄링 실패

문제: 네트워크 인지 스케줄링 미동작
```

### ❌ **4. 실험 데이터 부재**
```
실험 결과 디렉토리: 비어있음
Prometheus 메트릭: 수집 안됨
성능 비교 데이터: 없음

문제: 정량적 분석 불가능
```

## 🔧 **개선 방안**

### 1️⃣ **eBPF 에이전트 수정**

현재 문제:
```yaml
# 잘못된 placeholder 컨테이너
image: ubuntu:22.04
command: ["/bin/bash", "-c"]
args: ["apt-get update && apt-get install -y curl bpftrace..."]
```

해결책:
```yaml
# 실제 eBPF 바이너리 실행
image: ebpf-edge-agent:latest  # 실제 빌드된 이미지
securityContext:
  privileged: true
  capabilities:
    add: ["BPF", "SYS_ADMIN"]
volumeMounts:
- name: bpf-fs
  mountPath: /sys/fs/bpf
- name: debugfs  
  mountPath: /sys/kernel/debug
```

### 2️⃣ **실제 RTT 수집 구현**

문제: 시뮬레이션만 실행
```bash
echo "eBPF metrics collection simulated"
```

해결책: bpftrace로 즉시 RTT 수집
```bash
bpftrace -e '
kprobe:tcp_rcv_established {
  $sk = (struct tcp_sock *)arg0;
  $srtt = $sk->srtt_us >> 3;
  printf("RTT: %d us\n", $srtt);
}'
```

### 3️⃣ **스케줄러 Extender 활성화**

현재: HTTP 서비스만 배포, 실제 스케줄러 연동 안됨

해결책: kube-scheduler 설정 수정
```yaml
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    score:
      enabled:
      - name: NodeResourcesFit
  extenders:
  - urlPrefix: "http://network-aware-scheduler-extender.kube-system:8080"
    filterVerb: "filter"
    prioritizeVerb: "prioritize"
    weight: 100
    ignoredResources: []
```

## 🎯 **즉시 실행 가능한 개선**

### A. 실제 RTT 측정 시작
```bash
# bpftrace로 RTT 실시간 수집
sudo bpftrace -e '
kprobe:tcp_rcv_established {
  $sk = (struct tcp_sock *)arg0;
  $srtt = $sk->srtt_us >> 3;
  @rtt_hist = hist($srtt / 1000);  # milliseconds
}
interval:s:5 { print(@rtt_hist); clear(@rtt_hist); }'
```

### B. 네트워크 교란 검증
```bash
# ping으로 RTT 변화 확인
ping -c 10 cluster2  # 정상
sudo tc qdisc add dev enp0s3 root netem delay 50ms
ping -c 10 cluster2  # 교란 후
```

### C. 실제 성능 측정
```bash
# 워크로드 응답시간 측정
time curl http://nginx-service.workloads.svc.cluster.local/
```

## 📊 **재실험 계획**

### 단계 1: 기본 RTT 수집 (10분)
```bash
# 각 노드에서 RTT 측정
for node in cluster1 cluster2 cluster3; do
  ssh $node "bpftrace -e 'kprobe:tcp_rcv_established { @rtt = hist((((struct tcp_sock *)arg0)->srtt_us >> 3) / 1000); } interval:s:30 { print(@rtt); exit(); }'"
done
```

### 단계 2: 네트워크 교란 + 측정 (20분)
```bash
# S1 시나리오 재실행 (정확한 인터페이스로)
sudo tc qdisc add dev enp0s3 root netem delay 20ms 5ms
./simple-load-test.sh  # 부하 + RTT 측정
sudo tc qdisc del dev enp0s3 root
```

### 단계 3: 스케줄링 비교 (30분)
```bash
# 기본 vs 제안 스케줄러 A/B 테스트
kubectl scale deployment nginx --replicas=0
kubectl scale deployment nginx --replicas=6
# 노드 분산 비교 측정
```

## 🔥 **현실적 평가**

### ✅ **실제 달성한 것:**
- 3노드 클러스터 구축 완료
- 실험 자동화 프레임워크 완성
- 네트워크 교란 시스템 동작 확인
- 워크로드 배포 및 관리 성공

### ❌ **실패한 핵심 목표:**
- eBPF 실시간 RTT 수집 미달성
- 네트워크 인지 스케줄링 미동작  
- 정량적 성능 비교 데이터 부재
- Prometheus 메트릭 파이프라인 불완전

## 💡 **결론**

**현재 상태: 실험 인프라 80% 완성, 핵심 기능 20% 달성**

문제의 핵심은 eBPF 프로그램이 실제로 로드되지 않아서 RTT 데이터 수집이 안 되고, 따라서 네트워크 인지 스케줄링의 효과를 측정할 수 없다는 것입니다.

**하지만 이것은 구현 문제이지 아이디어 자체의 문제는 아닙니다.** 

실험 프레임워크는 훌륭하게 구축되었고, bpftrace로 즉시 RTT 측정을 시작할 수 있으며, 네트워크 교란도 실제로 효과가 있음을 확인했습니다.

**다음 단계에서 실제 eBPF 프로그램을 동작시키면 의미 있는 결과를 얻을 수 있을 것입니다!** 🚀
