# clickhouse-lab

로컬 macOS(Colima + [kind](https://kind.sigs.k8s.io/))에서 [Altinity Kubernetes
Operator for ClickHouse](https://github.com/Altinity/clickhouse-operator)와
ClickHouse Keeper를 이용해 ClickHouse 클러스터(현재 **4샤드 × 3레플리카**, 처음엔
3×3으로 시작해 실험 중 확장)를 구성하고, 장애 복구·로드밸런싱·운영 동작을
실습하기 위한 실험 환경입니다.

## 구성

- **kind**: control-plane 1 + worker 3 노드 로컬 Kubernetes 클러스터
- **Altinity ClickHouse Operator** (Helm 설치)
- **ClickHouseKeeperInstallation (CHK)**: Keeper 3노드 앙상블 (좌표 조정)
- **ClickHouseInstallation (CHI)**: ClickHouse 4샤드 × 3레플리카 (PVC 기반 영구 스토리지)
- **Prometheus + Grafana**: 오퍼레이터/ClickHouse 메트릭 관측

```
manifests/
├── kind-config.yaml     # kind 클러스터 정의 (4노드)
├── chk.yaml              # ClickHouseKeeperInstallation (Keeper 3노드)
├── chi.yaml               # ClickHouseInstallation (4샤드 x 3레플리카, PVC 포함)
└── monitoring/           # Prometheus + Grafana 매니페스트
```

## 시작하기

전체 설치 절차, 검증 방법, 실험 시나리오는 **[GUIDE.md](./GUIDE.md)**를 참고하세요.

```bash
kind create cluster --config manifests/kind-config.yaml
helm repo add altinity https://helm.altinity.com
helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace clickhouse --create-namespace
kubectl apply -f manifests/chk.yaml
kubectl apply -f manifests/chi.yaml
```

## 다뤄본 실험

- 샤딩(`Distributed`) + 복제(`ReplicatedMergeTree`) 기본 동작 검증
- 파드 삭제 후 자동 복구: PVC 유지 시 vs. 진짜 디스크 유실 시 차이
- 샤드 전체 다운 시 `skip_unavailable_shards` 동작
- `Distributed` 테이블 `load_balancing` 정책 5종 (`in_order`, `random`,
  `nearest_hostname`, `round_robin`, `first_or_random`) 비교, 장애 시 폴백 동작
- Keeper 노드 장애 내성 (쿼럼 상실 시 쓰기 블로킹, 쿼럼 복구 시 자동 재개)
- Prometheus + Grafana로 오퍼레이터/ClickHouse 메트릭 관측
- 클러스터 확장 & 수동 리샤딩 (3→4 샤드, 자동 재분배는 없다는 것 실증)
- 무중단 롤링 업그레이드 (버전 업그레이드는 되지만 다운그레이드는 지원 안 됨)
- 부하 테스트 & `max_parallel_replicas` (이 환경 규모에선 오히려 역효과)
- `ALTER TABLE UPDATE/DELETE` mutation 전파, TTL은 병합 시점에만 평가된다는 것
- 네트워크 파티션(스플릿 브레인) 시뮬레이션 — Keeper Raft의 자동 재합류 확인

자세한 명령어와 결과는 [GUIDE.md](./GUIDE.md)에 정리돼 있습니다.

## 프로덕션 운영 가이드

이 랩에서의 실험 결과를 근거로, 실제 운영 환경에서 ClickHouse를 고성능·고가용으로
운영하기 위한 설정/체크리스트는 **[PRODUCTION.md](./PRODUCTION.md)**를 참고하세요.

이 랩 클러스터를 그 체크리스트에 대고 실제로 점검한 결과는
**[AUDIT.md](./AUDIT.md)**에 정리돼 있습니다.

PRODUCTION.md를 AWS(EKS + Altinity 오퍼레이터) 환경에 구체적으로 적용하는 방법은
**[PRODUCTION-AWS.md](./PRODUCTION-AWS.md)**를 참고하세요.

## 샘플 애플리케이션

이 랩 클러스터 위에서 동작하는 ClickHouse + Java(Spring Boot) 표준 스켈레톤
(앱 푸시 발송/클릭 로그 → Materialized View 기반 실시간 CTR 통계)은
**[apps/push-click-service](./apps/push-click-service)**를 참고하세요.

## LLM 에이전트 툴 콜링

ClickHouse를 LLM 에이전트가 직접(MCP) 또는 앱을 경유해(OpenAPI/AgentCore
Gateway) 툴로 호출하는 두 가지 경로 비교와, `altinity-mcp`로 이 랩 클러스터에
실제 연결해 검증한 결과는 **[TOOL-CALLING.md](./TOOL-CALLING.md)**를
참고하세요.

## Kafka 테이블 엔진

Redpanda(Kafka 호환)를 실제로 배포하고 ClickHouse `Kafka` 엔진 + MV로
연동해 검증한 결과 — poison pill(깨진 메시지가 전체 소비를 멈추는 현상)와
`kafka_skip_broken_messages`로 해결하는 법, 컨슈머 그룹 변경 시 재처리/중복
이슈 등은 **[KAFKA-INTEGRATION.md](./KAFKA-INTEGRATION.md)**를 참고하세요.
