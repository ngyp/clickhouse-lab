# A6 · a6-event-hll_dedup_summary-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | event → HLL |
| 시간·고객 그룹별 | dedup → summary → count |
| 생성 흐름 | event → dedup → summary |
| 저장 대상 | event, dedup, 상품별·그룹별 summary |
| 독립 DB | `shop_a6` |

## 검증하려는 것

A6는 전체 누적 distinct journey를 원본 event의 `uniqHLL12`로 빠르게 근사하고, 시간·고객 그룹별 상세는 A5와 같은 dedup 기반 exact summary로 제공합니다. 다음 조건을 확인합니다.

1. 전체와 일반·집중 상품의 HLL 상대 오차가 3% 이하다.
2. 상세 summary가 전체·이벤트 종류·상품·고객 그룹 기준값과 일치한다.
3. HLL과 summary 조회가 집중 상품에서도 서비스 조회에 사용할 수 있는 지연으로 끝난다.
4. 신규 event의 HLL 반영 시점과 summary 반영 시점을 구분할 수 있다.
5. 단일 replica 장애 중 두 조회 경로가 계속 성공하고 복구 뒤 값이 유지된다.

## 구현 구조

```text
shopping_events (ReplicatedMergeTree + Distributed)
        ├─ 직접 uniqHLL12 조회 ───────────────→ 전체 누적 근사값
        └─ local MV
             ↓
first_event_states_local (ReplicatedAggregatingMergeTree)
             ↓ snapshot/refresh
        ├─ event_summary_local ───────────────→ 시간별 exact
        └─ customer_group_summary_local ──────→ 시간·고객 그룹별 exact
```

HLL은 별도 summary가 아니라 원본 event를 조회할 때 계산합니다. 그래서 INSERT가 성공한 직후 새 event를 읽을 수 있지만, 조회 비용은 대상 원본 행 수에 비례합니다.

상세 summary의 현재 구현은 검증된 snapshot을 만드는 backfill입니다. `event → dedup`은 incremental MV지만 `dedup → summary` 자동 갱신과 대표 변경 보정은 구현하지 않았습니다. 같은 `SummingMergeTree` target에 backfill을 다시 실행하면 기존 count에 중복 가산되므로 주기 실행 작업으로 그대로 사용하면 안 됩니다.

## 파일

| 파일 | 내용 |
|---|---|
| [schema.sql](./schema.sql) | Replicated event·dedup·summary와 Distributed 테이블 |
| [backfill-dedup-from-common.sql](./backfill-dedup-from-common.sql) | 공통 원본을 여정 해시 버킷으로 나눠 shard 로컬 dedup 생성 |
| [backfill-summary.sql](./backfill-summary.sql) | 2GB 제한에서 event·고객 그룹 summary 생성 |
| [run-backfill-from-common.sh](./run-backfill-from-common.sh) | 대표 replica를 조회해 shard 순차, 기본 8버킷 backfill |
| [validate.sql](./validate.sql) | HLL 오차, exact summary 정합성, 복제 상태 검증 |
| [test-freshness.sql](./test-freshness.sql) | INSERT ACK 뒤 HLL·dedup 가시성과 summary 미갱신 검증 |
| [run-query-benchmarks.sh](./run-query-benchmarks.sh) | HLL과 exact summary 조회 반복 측정 |
| [run-replica-failure-test.sh](./run-replica-failure-test.sh) | replica 삭제 중 HLL·summary 혼합 조회와 복구 검증 |

## 실행

공통 원본을 생성한 뒤 A6 schema와 snapshot을 만듭니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery \
  < examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/schema.sql

examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/run-backfill-from-common.sh
```

검증과 성능·장애 테스트를 실행합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery --format PrettyCompact \
  < examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/validate.sql

kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery --format PrettyCompact \
  < examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/test-freshness.sql

examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/run-query-benchmarks.sh
examples/shopping-journey/cluster/a6-event-hll_dedup_summary-count/run-replica-failure-test.sh
```

## 실행 결과

2026-09-21, ClickHouse `26.9.1.1357`, 4 shard × 3 replica에서 공통 원본 22,200,000행을 사용했습니다. 일반 상품은 100개×100,000 journey이고 집중 상품은 1개×10,000,000 journey입니다.

### HLL 정확도

전체 상품을 합친 event 종류별 HLL은 모두 3% 기준을 통과했습니다.

| event 종류 | exact | HLL | 상대 오차 |
|---|---:|---:|---:|
| CART | 200,000 | 201,489 | 0.744% |
| CLICK | 1,000,000 | 996,204 | 0.380% |
| NOTIFY | 20,000,000 | 20,190,193 | 0.951% |
| PURCHASE | 100,000 | 100,822 | 0.822% |
| VIEW | 800,000 | 786,247 | 1.719% |

상품별로 보면 집중 상품의 다섯 event 종류는 0.068~1.481%로 통과했습니다. 일반 상품에서는 CLICK 5,000개가 5,167로 계산돼 상대 오차 3.340%로 기준을 넘었습니다. 나머지 일반 상품 네 종류는 0.300~2.600%였습니다.

따라서 `uniqHLL12`는 전체·고카디널리티 집계에는 이번 기준을 만족했지만, 3%를 모든 작은 상품 구간에 보장하는 경로로는 통과하지 못했습니다. 작은 구간도 3%가 강제 조건이면 exact 조회로 분기하거나 더 정확한 distinct 알고리즘을 별도로 평가해야 합니다.

### exact summary와 backfill

| 항목 | 결과 |
|---|---:|
| dedup 논리 대표 | 22,100,000행 |
| 이벤트 exact 합계 | 22,100,000, 기대값 일치 |
| 고객 그룹 귀속 합계 | 44,200,000, 기대값 일치 |
| 이벤트 종류별·일반/집중 상품 count | 모두 기대값 일치 |
| replica queue / delay | 0 / 0 |
| 최종 backfill 벽시계 시간 | 2분 5초 |

처음 버킷 없이 한 shard를 집계했을 때 메모리 한도 4.71GiB 근처에서 3.72GiB를 추가 할당하려다 `MEMORY_LIMIT_EXCEEDED`가 발생했습니다. 네 shard를 동시에 실행한 시도는 복제 부하가 겹쳐 Kubernetes API 연결이 끊기고 replica Pod 하나가 재시작했습니다.

최종 스크립트는 같은 journey가 항상 같은 버킷에 들어가도록 `intHash64(cityHash64(journey_id)) % 8`을 사용하고 shard를 순차 처리합니다. 각 shard에서 버킷당 원본은 약 69만 행으로 고르게 나뉘었습니다.

| 단계 | shard별 시간 | 최대 메모리 |
|---|---:|---:|
| dedup 8버킷 합계 | 17.16~18.36초 | 1.74GiB |
| 이벤트 summary | 5.68~5.94초 | 938.89MiB |
| 고객 그룹 summary | 5.84~6.05초 | 958.32MiB |

이 수치는 현재 로컬 클러스터의 초기 snapshot 생성 결과입니다. 운영 backfill은 shard 병렬도를 자원 한도에 맞춰 제한하고, Pod 재시작·memory tracking·replication queue를 함께 감시해야 합니다.

### 조회 성능

동시성 1에서 일반·집중 상품은 105회, 전체 HLL은 30회 실행했습니다. 시간은 서버 처리 시간입니다.

| 조회 | 반복 | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| 일반 상품 1개 HLL | 105 | 4ms | 6ms | 7ms |
| 집중 상품 1개 HLL | 105 | 48ms | 66ms | 82ms |
| 전체 데이터셋 event별 HLL | 30 | 85ms | 117ms | 122ms |
| 일반 상품 1개 시간별 exact summary | 105 | 3ms | 4ms | 5ms |
| 집중 상품 1개 시간별 exact summary | 105 | 4ms | 6ms | 7ms |
| 집중 상품 1개 시간·고객그룹별 exact summary | 105 | 12ms | 18ms | 20ms |

HLL은 별도 저장된 sketch를 합치는 구조가 아니라 원본을 직접 읽습니다. 이번 22.2M행에서는 전체 조회 p99 122ms였지만 데이터 보존 기간과 원본 행 수가 늘면 다시 부하 테스트해야 합니다.

### 반영 시점

전용 상품에 최초 event를 INSERT한 뒤 응답 직후 실행한 첫 SELECT에서 HLL 1과 dedup 대표가 확인됐습니다. 같은 journey의 재전송과 더 이른 event를 추가한 뒤에도 원본 3행, exact distinct 1, HLL 1이었고 dedup 대표 시간은 10시에서 09시로 바뀌었습니다.

상세 summary는 이 INSERT들 뒤에도 0이었습니다. 현재 A6에는 `dedup → summary` 자동 경로가 없기 때문입니다.

| 조회 경로 | 반영 시점 | 현재 상태 |
|---|---|---|
| event → HLL | 원본 INSERT ACK 뒤 첫 조회 | 즉시 가시성 확인 |
| event → dedup | incremental MV가 INSERT와 함께 처리 | 대표 변경 확인 |
| dedup → exact summary | snapshot backfill 실행 때만 | 자동 갱신 없음 |

현재 데이터에서 summary 두 종류를 shard 순차로 새 target에 생성하는 query 시간 합은 약 47초였습니다. 이를 주기 refresh로 운영한다면 새 shadow target 생성, 정합성 확인, 복제 완료, 서비스 target 교체가 추가로 필요합니다. 실행 주기를 `I`, 전체 refresh 시간을 `R`이라고 하면 일반적인 freshness lag는 `R` 이상 `I + R` 미만입니다. 현재 저장소에는 scheduler와 target 교체가 구현돼 있지 않습니다.

실시간 exact 상세가 필요하면 A5의 [실시간 보정 구현 보완사항](../a5-dedup_summary-count/correction-design.md)에 정의한 이전 bucket `-1`, 새 bucket `+1` 방식과 멱등 sink가 필요합니다. A6의 상세 경로도 같은 제약을 갖습니다.

### 단일 replica 장애

`chi-chi-cluster1-0-2-0` Pod를 삭제한 뒤, 집중 상품 CLICK의 HLL과 exact summary를 함께 읽는 조회를 동시성 4로 2,000회 실행했습니다.

| 항목 | 결과 |
|---|---:|
| 성공 / 실패 | 2,000 / 0 |
| 장애 중 p50 / p95 / p99 | 152ms / 236ms / 320ms |
| Pod 삭제 요청 → 새 Pod Ready | 16초 |
| 복구 후 replica queue / delay | 0 / 0 |
| 복구 후 HLL / exact summary | 변경 없음 |

이 결과는 단일 replica 읽기 장애만 검증합니다. 적재 중 장애, shard 전체 장애, Keeper 장애, summary refresh 중 장애는 아직 실행하지 않았습니다.

## 판정

| 검증 항목 | 판정 |
|---|---|
| 전체 event 종류 HLL 오차 3% 이하 | 통과 |
| 상품·event 종류별 HLL 오차 3% 이하 | 실패: 일반 상품 CLICK 3.340% |
| snapshot exact summary 정합성 | 통과 |
| HLL·summary 조회 성능 | 통과 |
| event HLL INSERT 뒤 가시성 | 통과 |
| exact summary 자동 갱신·대표 변경 보정 | 실패: 미구현 |
| 단일 replica 읽기 연속성과 복구 | 통과 |
| A6 전체 운영 준비 | 미통과 |

A6는 전체 누적을 근사값으로 허용할 때 A5보다 빠르게 최신 event를 보여줄 수 있습니다. 프로덕션 적용 전에는 작은 구간의 HLL 허용 오차 정책을 정하고, 상세 summary의 refresh 또는 실시간 보정 경로를 구현해야 합니다. 운영 지표에는 HLL query latency·read rows, summary freshness timestamp, refresh duration/failure, correction lag, memory·spill, replica queue/delay와 active replica 수가 필요합니다.
