# eBPF-based Edge Node Selection for Network-Aware Kubernetes Scheduling

## 🎯 실험 목표
eBPF 기반 텔레메트리를 사용한 "엣지 노드 선택(네트워크 인지 스케줄링)"이 기본 스케줄링 대비 지연·드롭을 줄이고 QPS/CPU 효율을 개선하는지 검증.

## 📊 주요 평가지표
- **지연**: p50/p99 response latency
- **신뢰성**: 오류/드롭률 
- **처리량**: QPS (Queries Per Second)
- **효율성**: CPU/백만 메시지
- **안정성**: 스케줄 안정성(재스케줄 빈도)
- **운영성**: MTTR(스케줄러 롤백 시간), 도입/운영 난이도

## 🏗️ 프로젝트 구조

```
├── ebpf-agent/          # eBPF 텔레메트리 에이전트
├── scheduler/           # 커스텀 스케줄러 (Framework 플러그인)
├── scheduler-extender/  # 스케줄러 Extender (대안)
├── workloads/          # 테스트 워크로드
├── monitoring/         # Prometheus + Grafana 설정
├── infrastructure/     # 클러스터 설정 (kubeadm, Cilium)
├── experiments/        # 실험 스크립트 및 시나리오
├── scripts/           # 유틸리티 스크립트
└── docs/              # 상세 문서
```

## 🚀 빠른 시작

### 1. 클러스터 구축
```bash
cd infrastructure
./setup-cluster.sh
```

### 2. eBPF 에이전트 배포
```bash
cd ebpf-agent
make deploy
```

### 3. 스케줄러 설치
```bash
cd scheduler
make deploy
```

### 4. 실험 실행
```bash
cd experiments
make experiment SCENARIO=S1 MODE=proposed RPS=500
```

## 📋 실험 시나리오
- **S1**: 네트워크 지연 증가
- **S2**: 패킷 손실/재전송 유발  
- **S3**: 대역폭 제한
- **S4**: CPU 압력 주입
- **S5**: 노드 부분 장애

## 🔬 스케줄링 모드
- **Baseline**: 기본 K8s 스케줄러
- **NetworkAware**: 네트워크 인지 기준선
- **Proposed**: eBPF 기반 제안 방식

## 📈 메트릭 수집
- RTT (p50/p99)
- TCP 재전송률
- 패킷 드롭률 (reason별)
- 스케줄러 대기시간
- CPU 사용률

## 🛡️ 보안 및 컴플라이언스
- L7 바디 수집 금지 (메타데이터만)
- PII 정보 수집 금지
- 최소 권한 원칙 적용
# ebpfEdgeNode
