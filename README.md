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
- 백업/복구 실전 훈련(재해복구 드릴) — `ON CLUSTER` 없이 백업하면 샤드 1개분만
  조용히 백업되는 함정을 실제로 겪고, 올바른 방법으로 전체 클러스터 삭제 후 복구까지 검증
- 쿼리 자원 통제(`max_memory_usage`, `max_execution_time`, `KILL QUERY`,
  동시 쿼리 제한, `QUOTA`)
- 인제스트 내압 — `parts_to_delay_insert`→`parts_to_throw_insert`로 이어지는
  선형 백프레셔를 강제로 재현
- 무중단 스키마 변경 — `ADD`/`MODIFY COLUMN`은 부하 중에도 무중단이지만,
  `Distributed` 테이블은 별도로 ALTER해야 한다는 함정 확인
- INSERT 멱등성/중복제거 — `insert_deduplicate`가 `Distributed` 테이블을
  거치면 작동하지 않는다는 함정 확인 (Kafka 재처리 중복 문제의 근본 원인 규명)
- Projection으로 쿼리 가속 — 자동 선택 확인, `Distributed` 테이블은
  `ADD COLUMN`과 달리 별도 조치 없이도 투명하게 혜택을 받는다는 것 확인
- 메모리 스필오버 검증(GROUP BY/JOIN/ORDER BY) — 같은 메모리 캡에서 스필
  비활성/활성 대조, `grace_hash`의 초기 버킷 수·새로 추가된
  `max_bytes_ratio_before_external_sort` 게이트처럼 "설정만 켜서는 부족한"
  숨은 조건들을 실측
- CHI `profiles`로 메모리/스필 설정을 클러스터 전체 기본값으로 — 파드 재시작
  없이 12개 노드 전체에 반영되고, `SETTINGS` 없는 쿼리도 동일하게 보호받는
  것을 실측
- Query Queue & 동시성 제한 — `queue_max_wait_ms`는 서버 레벨
  `max_concurrent_queries`에만 적용되고 프로필 레벨 한도는 무시함을 확인,
  HTTP 인터페이스는 429/503이 아니라 500을 반환한다는 것도 실측
- 배치 vs 실시간 사용자 분리 — 사용자별 프로필(동시성/실행시간)로 완전한
  워크로드 격리를 확인. CPU Workload Scheduling(`CREATE WORKLOAD`)도 시도해
  스레드 상한은 검증했으나 우선순위 기반 동시 실행 공정성은 미해결로 남김

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

## 도메인 예제

상품 안내·클릭·구매 이벤트를 다루는
[쇼핑몰 구매 여정 예제](./examples/shopping-journey/README.md)를 제공합니다.
ERD, 단일 노드용 DDL, 샘플 데이터와 조회 SQL을 포함하며, 기존 앱과 별도 DB를 사용합니다.
클러스터 적용과 실행 검증은 아직 진행하지 않은 초안입니다.

## LLM 에이전트 툴 콜링

ClickHouse를 LLM 에이전트가 직접(MCP) 또는 앱을 경유해(OpenAPI/AgentCore
Gateway) 툴로 호출하는 두 가지 경로 비교와, `altinity-mcp`로 이 랩 클러스터에
실제 연결해 검증한 결과는 **[TOOL-CALLING.md](./TOOL-CALLING.md)**를
참고하세요.

## Kafka 테이블 엔진

Redpanda(Kafka 호환)를 실제로 배포하고 ClickHouse `Kafka` 엔진 + MV로
연동해 검증한 결과 — poison pill(깨진 메시지가 전체 소비를 멈추는 현상)와
`kafka_skip_broken_messages`로 해결하는 법, 컨슈머 그룹 변경 시 재처리/중복
이슈, fan-out/MV 삭제/스키마 불일치/컨슈밍 중 파드 재시작 등 엣지 케이스는
**[KAFKA-INTEGRATION.md](./KAFKA-INTEGRATION.md)**를 참고하세요.

## chDB vs pandas 벤치마크

pandas 대체재 리서치 후, 3,200개 컬럼·프로세스 메모리 한도를 넘는 데이터로
chDB와 pandas를 같은 메모리 캡 아래 실측 비교한 결과(pandas는 8GB로도 OOM,
chDB는 1.5GB로 성공)는 **[CHDB-BENCHMARK.md](./CHDB-BENCHMARK.md)**를,
평범한 크기의 데이터로 chDB/pandas/Polars/DuckDB 네 엔진의 속도를 비교한
결과(top-N 정렬에서 API 선택이 성패를 가른 사례 포함)는
**[CHDB-SPEED-BENCHMARK.md](./CHDB-SPEED-BENCHMARK.md)**를 참고하세요.
