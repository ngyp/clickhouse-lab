# A2 · a2-event-hll_dedup-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | event → HLL |
| 시간·고객 그룹별 | dedup → 직접 count |
| 생성 흐름 | event → dedup |
| 필요한 저장 대상 | event, dedup |
| 독립 DB | shop_a2 |

## 구현 구조

```text
shopping_events (Distributed, journey_id sharding)
        ↓
shopping_events_local (ReplicatedMergeTree)
        ↓ local MV
first_event_states_local (ReplicatedAggregatingMergeTree)
        ↓
first_event_states (Distributed)
        ├─ first_events (전체 검증용 View)
        └─ first_events_by_product(product_id) (상품 조회용 parameterized View)
```

같은 `journey_id`의 이벤트를 같은 shard에 보내고, shard 내부에서는 3개 replica로 복제합니다. 전체 누적은 `shopping_events`에서 HLL로 조회하고, 시간·고객 그룹별 상세 결과는 `first_events`에서 정확 count합니다.

하나의 `journey_id`가 항상 같은 `product_id`에 속한다는 데이터 규칙을 사용해 dedup 상태의 정렬 키를 `(product_id, journey_id, event_kind)`로 둡니다. 상품 조건을 상태 집계 안쪽에 작성하면 관련 상품의 mark만 읽을 수 있습니다.

일반 `first_events` View 바깥에 작성한 `WHERE product_id = ...`는 내부 Distributed 집계까지 자동으로 내려가지 않을 수 있습니다. 서비스 조회는 `first_events_by_product(product_id = ...)`를 사용해 조건을 상태 테이블 안쪽에 강제합니다. 일반 View는 전체 정합성 검사에만 사용합니다.

공통 성능 snapshot을 비교할 때 전체 누적 HLL은 `shop_benchmark.shopping_events`를 조회합니다. A2의 dedup state는 원본을 다시 적재하지 않고 `run-backfill-from-common.sh`로 생성합니다. 실시간 MV 처리량을 측정할 때만 A2의 `shopping_events`에 별도 입력합니다.

## 파일

| 파일 | 내용 |
|---|---|
| [schema.sql](./schema.sql) | Replicated 로컬 테이블, Distributed 테이블, 로컬 MV와 병합 View |
| [sample-data.sql](./sample-data.sql) | standalone과 동일한 고정 샘플 6행 |
| [queries.sql](./queries.sql) | HLL, dedup count, shard 분산 확인 |
| [generate-large-data.sql](./generate-large-data.sql) | journey 수를 인자로 받는 대용량 합성 데이터 생성 |
| [check-large-data.sql](./check-large-data.sql) | 예상·실제 행 수와 HLL 상대 오차 확인 |
| [generate-performance-data.sql](./generate-performance-data.sql) | 분산 상품군과 대규모 집중 상품을 100만 journey chunk로 생성하는 SQL |
| [run-performance-data.sh](./run-performance-data.sh) | 20개 chunk를 순서대로 실행하는 스크립트 |
| [check-performance-data.sql](./check-performance-data.sql) | 성능 데이터의 분포·대표 event·HLL 오차 검증 |
| [backfill-from-common.sql](./backfill-from-common.sql) | 공통 원본의 로컬 shard에서 A2 dedup state 생성 |
| [run-backfill-from-common.sh](./run-backfill-from-common.sh) | shard별 대표 replica를 인자로 받아 backfill 순차 실행 |

## 실행 순서

저장소 루트에서 실행합니다.

기본 `manifests/chi.yaml` 배포는 다음 기본값을 그대로 사용합니다. free operator 배포에서는 `export LAB_CLICKHOUSE_POD=clickhouse-0`으로 바꿉니다.

```bash
export LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
```

1. 실제 토폴로지를 확인합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client -q "
       SELECT shard_num, replica_num, host_name
       FROM system.clusters
       WHERE cluster = 'cluster1'
       ORDER BY shard_num, replica_num"
   ```

2. A2 스키마를 `cluster1`의 모든 ClickHouse Pod에 생성합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/schema.sql
   ```

3. 고정 샘플을 넣고 결과를 확인합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/sample-data.sql

   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/queries.sql
   ```

4. 대용량 데이터는 `journey_count`를 지정해 생성합니다. 먼저 100만으로 검증하고 자원 여유를 확인한 뒤 1천만 이상으로 높입니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --max_memory_usage=2000000000 \
     --param_journey_count=1000000 \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/generate-large-data.sql

   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --param_journey_count=1000000 --format PrettyCompact \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/check-large-data.sql
   ```

대용량 생성기는 같은 범위를 다시 실행하면 원본 중복이 추가됩니다. 같은 DB에서 단계적으로 크기를 늘리지 말고, 케이스별 새 DB 또는 서로 겹치지 않는 데이터 범위를 사용해야 합니다.

| journey_count | 생성 원본 | 대표 이벤트 | 용도 |
|---:|---:|---:|---|
| 1,000,000 | 1,110,000 | 1,105,000 | 기능·분산·HLL 오차 확인 |
| 10,000,000 | 11,100,000 | 11,050,000 | 로컬 성능 비교 후보 |
| 100,000,000 | 111,000,000 | 110,500,000 | 저장 공간·실행 시간 확인 후 수행할 스트레스 후보 |

현재 생성기는 20,000개 상품에 journey를 분산합니다. 상품 하나에 100만~1,000만 journey가 몰리는 최악 조건은 별도의 hot-product 성능 데이터로 추가해야 합니다. 아래 100만 결과를 단일 상품 최악 조건의 성능 결과로 해석하지 않습니다.

5. A2 자체의 실시간 MV·적재 처리량을 독립적으로 측정할 때만 A2 DB에 성능 데이터를 생성합니다. A1~A7 조회 비교에서는 이 단계를 실행하지 않고 공통 원본을 사용합니다.

   ```bash
   LAB_MAX_MEMORY_USAGE=2000000000 \
     examples/shopping-journey/cluster/a2-event-hll_dedup-count/run-performance-data.sh

   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     < examples/shopping-journey/cluster/a2-event-hll_dedup-count/check-performance-data.sql
   ```

   | 구분 | 상품 수 | 상품당 journey | 전체 journey | 예상 원본 event |
   |---|---:|---:|---:|---:|
   | 분산 상품군 | 100 | 100,000 | 10,000,000 | 11,100,000 |
   | 대규모 집중 상품 | 1 | 10,000,000 | 10,000,000 | 11,100,000 |
   | 전체 데이터셋 | 101 | 혼합 | 20,000,000 | 22,200,000 |

   용어와 각 조회 범위의 의미는 [공통 실험 기준의 데이터 분포별 의미](../common/README.md#데이터-분포별-의미)를 따릅니다. 분산 상품 한 개, 분산 상품 10개·100개, 대규모 집중 상품, 전체 데이터셋 순서로 조회 범위를 넓히면 같은 데이터에서 약 11만~2,220만 원본 행 구간을 비교할 수 있습니다. 모든 A1~A7 케이스에 같은 product와 journey 분포를 사용해야 합니다.

   로컬 kind 환경에서 2천만 journey를 하나의 INSERT로 생성하면 MV와 3중 복제가 동시에 큰 블록을 처리해 OOM이 발생할 수 있습니다. 실행 스크립트는 분산 상품군과 대규모 집중 상품을 각각 100만 journey 단위로 나눠 적재합니다. 기존 `perf-*` 데이터가 있으면 중복을 막기 위해 실행을 중단합니다.

6. A1~A7 조회 비교에서는 공통 원본 적재가 끝난 뒤 A2 dedup state만 backfill합니다.

   ```bash
   # 기본 manifests/chi.yaml: 4 shard의 대표 replica가 기본값입니다.
   examples/shopping-journey/cluster/a2-event-hll_dedup-count/run-backfill-from-common.sh

   # GUIDE(free operator).md: 3 shard의 대표 replica를 명시합니다.
   examples/shopping-journey/cluster/a2-event-hll_dedup-count/run-backfill-from-common.sh \
     clickhouse-0 clickhouse-3 clickhouse-6
   ```

   인자를 생략하면 기본 Operator 4-shard 대표 Pod인 `chi-chi-cluster1-{0,1,2,3}-0-0`을 사용합니다. 다른 Pod 이름은 위치 인자 또는 공백으로 구분한 `LAB_BACKFILL_PODS`로 전달할 수 있습니다. backfill은 `max_memory_usage=4GB`, `max_bytes_before_external_group_by=512MiB`를 기본 적용하며 환경 변수로 조정할 수 있습니다.

   backfill 스크립트는 기존 dedup state가 한 행이라도 있으면 중복 실행을 막기 위해 중단합니다. 3단계의 고정 샘플이나 5단계의 독립 성능 데이터를 실행한 DB를 재사용하지 말고, 공통 snapshot 비교용 `shop_a2`를 새로 생성해 실행합니다.

현재 lab처럼 `remote_servers`가 XML 기반 `cluster_internal` 사용자를 지정한다면 그 계정에 `shop_a2.*`의 `SELECT, INSERT` 권한이 필요합니다. XML 사용자는 SQL `GRANT`로 변경할 수 없으므로 ConfigMap의 사용자 정의를 수정한 뒤 StatefulSet을 순차 재시작해야 합니다.

## 실행 결과

2026-09-21, ClickHouse `26.8.3.105`, `GUIDE(free operator).md`의 별도 3 shard × 3 replica 배포에서 확인했습니다. 저장소 기본 `manifests/chi.yaml`의 4 shard × 3 replica 배포 결과가 아닙니다.

### 고정 샘플

| 항목 | 결과 |
|---|---:|
| Distributed 원본 행 | 6 |
| 대표 이벤트 | 5 |
| 이벤트별 HLL | NOTIFY·CLICK·VIEW·CART·PURCHASE 각각 1 |
| 시간별·그룹별 count | [데이터 결과 기준](../../expected/data-result.md)과 일치 |

### 100만 journey

| 항목 | 예상 | 실제 |
|---|---:|---:|
| 중복 포함 생성 원본 | 1,110,000 | 1,110,000 |
| 대표 이벤트 | 1,105,000 | 1,105,000 |

| event_kind | 정확 count | HLL | 상대 오차 |
|---|---:|---:|---:|
| NOTIFY | 1,000,000 | 995,416 | 0.458% |
| CLICK | 50,000 | 49,636 | 0.728% |
| VIEW | 40,000 | 39,919 | 0.202% |
| CART | 10,000 | 9,994 | 0.060% |
| PURCHASE | 5,000 | 5,029 | 0.580% |

세 shard의 원본 행은 369,634 / 370,749 / 369,623행이었습니다. 각 shard의 세 replica는 서로 같은 행 수였고 `shopping_events_local`과 `first_event_states_local`의 replication queue 및 absolute delay는 모두 0이었습니다. 이 shard 행 수에는 먼저 넣은 고정 샘플 6행이 포함됩니다.

현재 결과는 데이터 정확성 검증입니다. 조회 p95·p99, 적재 처리량, CPU·메모리는 [성능 기준](../../expected/performance.md)의 목표값을 정한 뒤 별도로 측정합니다.

### 2천만 journey 성능 데이터 1차 시도

2026-09-21에 분산 상품 100개×10만 journey와 대규모 집중 상품 1개×1천만 journey를 한 번에 적재하는 방식으로 시험했습니다. 이 방식은 실패했으며 정식 A1~A6 비교 결과로 사용하지 않습니다.

| 항목 | 결과 |
|---|---:|
| 적재 벽시계 시간 | 56분 46초 |
| 예상 원본 event | 22,200,000행 |
| 실제 원본 event | 23,777,820행 |
| 원본 상태 | 일부 블록 재전송 중복 및 대규모 집중 상품 일부 누락 |
| Pod 장애 | `clickhouse-7`, `clickhouse-4` 각각 OOMKilled 1회 |
| dedup 전체 count | 원격 replica EOF로 실패 |
| 측정 종료 시 원본 압축 크기 | 565.91 MiB, shard 합계·replica 1벌 기준 |
| 측정 종료 시 dedup state 압축 크기 | 917.54 MiB, shard 합계·replica 1벌 기준 |

원본 HLL 경로의 참고 측정값은 다음과 같습니다. 장애와 background merge가 발생한 데이터이므로 구조 간 최종 비교값은 아닙니다.

| 조회 | 반복 | p50 | p95 | 결과 |
|---|---:|---:|---:|---|
| 분산 상품 1개, 약 10만 journey | 10회 | 3.109초 | 6.824초 | 완료 |
| 대규모 집중 상품, 목표 1천만 journey | 5회 | 1.738초 | 4.531초 | 완료, 약 48만 journey 누락 추정 |

이 시도로 단일 대형 INSERT가 현재 로컬 자원 한계를 넘는다는 점과, 당시 A2의 `first_events` View가 상품 조건보다 먼저 전체 dedup state를 병합해 직접 count에 불리하다는 점을 확인했습니다. 이후 스키마에서는 `product_id`를 dedup 상태의 첫 정렬 키로 올렸고, 다음 비교는 chunk 적재로 데이터 정합성을 먼저 통과한 뒤 수행합니다.

위 결과는 실패 원인을 보존하기 위한 기록입니다. 아래 재시험에서는 기존 A2 DB를 초기화하고 변경된 정렬 키와 공통 snapshot backfill을 적용했습니다.

### 공통 snapshot 기반 A2 재시험

2026-09-21, ClickHouse `26.8.6.5`, `GUIDE(free operator).md`의 별도 3 shard × 3 replica 배포에서 검증을 통과한 공통 원본 22,200,000행을 사용했습니다. A2 원본은 다시 적재하지 않았습니다.

이 결과는 [공통 실험 기준의 성능 측정 해석](../common/README.md#공통-원본-조회-기준값)을 따르는 1차 예비 측정입니다. 표의 `반복` 열이 실제 실행 횟수이며, 모든 조회를 10회씩 수행한 결과는 아닙니다.

| 항목 | 결과 |
|---|---:|
| dedup backfill 시간 | 11분 26.72초 |
| 대표 event state | 22,100,000행 |
| dedup state 압축 크기 | 852.60 MiB, shard 합계·replica 1벌 기준 |
| replica queue·delay | 0 / 0 |
| Pod 재시작·OOM | 0 |

분산 상품 1개와 대규모 집중 상품의 이벤트 종류별 state 수가 모두 예상값과 일치했습니다.

| 조회 | 반복 | p50 | p95 | 결과 |
|---|---:|---:|---:|---|
| 분산 상품 1개, parameterized View 시간별 exact count | 10회 | 816ms | 1.243초 | 성공 |
| 대규모 집중 상품, parameterized View 시간별 exact count | 1회 | - | - | 3분 12초 후 자원 보호를 위해 중단 |
| 전체 데이터셋 dedup count | 1회 | - | - | 1분 43초 후 메모리 한도 4.70 GiB 초과 |

일반 `first_events` View에 외부 상품 조건을 건 첫 쿼리는 조건 pushdown이 되지 않아 86.140초가 걸렸습니다. 최종 측정은 `first_events_by_product(product_id=...)`를 사용했습니다. A2 직접 count는 분산 상품 1개 규모에서는 동작하지만 대규모 집중 상품 규모에는 적합하지 않습니다.

## 1차 결론과 한계

현재 데이터와 로컬 kind 자원에서는 전체 누적값을 빠르게 보여주는 용도로 event HLL이 가장 현실적이었습니다. 분산 상품 1개의 원본 111,000행은 p50 22ms, 대규모 집중 상품의 원본 11,100,000행은 p50 235ms였습니다. 다만 HLL은 근사값이고 최초 이벤트의 시간·고객 그룹 귀속을 결정하지 못합니다. 분산 상품 `CLICK`에서는 상대 오차가 3.340%로 초기 허용 기준 3%를 넘었습니다.

A2 dedup 조회가 느려지는 기준은 전체 테이블 크기만이 아니라 **조회 조건에 걸린 aggregate state 수**입니다. 분산 상품 1개의 state 110,500개는 p50 816ms로 처리됐지만, 대규모 집중 상품의 state 11,050,000개는 3분 12초 안에 끝나지 않았습니다. 이 수치는 현재 lab 자원의 관측값이며 운영 환경의 절대 한계값은 아닙니다.

현재 원본 22,200,000행은 dedup 후에도 22,100,000개의 state가 남습니다. 중복 제거율이 약 0.45%라서 읽는 행은 거의 줄지 않지만, 조회 시 다음 작업이 추가됩니다.

```text
product_id 조건으로 state 조회
→ shard별 AggregateFunction 상태 역직렬화
→ argMinMerge로 최초 이벤트 확정
→ 대표 Tuple 복원
→ 시간·고객 그룹별 exact count
```

따라서 현재 A2에서는 원본 감소 효과보다 넓은 `argMinState`의 저장 공간과 병합 비용이 더 큽니다. 원본은 replica 1벌 기준 499.39 MiB였지만 dedup state는 852.60 MiB였습니다.

### MV와 argMinMerge의 역할

MV는 새로 들어온 INSERT 블록 안에서 `argMinState`를 만들지만, 이전에 저장된 state를 다시 읽어 최종 대표 이벤트까지 확정하지는 않습니다.

```text
원본 INSERT
→ MV가 현재 INSERT 블록의 argMinState 생성
→ AggregatingMergeTree에 partial state 추가
→ background merge가 같은 키의 state를 비동기로 병합
→ 조회 시 argMinMerge가 남아 있는 state를 최종 병합
```

예를 들어 동일한 `(journey_id, event_kind)`의 이벤트가 서로 다른 INSERT로 들어오면 일시적으로 두 state가 존재할 수 있습니다. `AggregatingMergeTree`가 이를 background merge로 합치지만 완료 시점은 보장되지 않습니다. 따라서 적재 직후에도 정확한 최초 이벤트를 반환하려면 조회에서 `argMinMerge`가 필요합니다.

이번 공통 snapshot backfill은 shard의 전체 원본을 한 번에 `GROUP BY`해 키당 state를 거의 하나씩 만들었으므로, 작은 INSERT가 반복되는 실시간 환경보다 유리한 조건입니다. 운영에서는 partial state 수와 part 수에 따라 조회 비용이 더 달라질 수 있습니다.

단순 `count()`는 현재 저장된 물리 state 행 수를 셀 뿐, 논리적으로 중복 제거된 이벤트 수를 항상 보장하지 않습니다. 조회에서 `argMinMerge`를 제거하려면 별도 refresh·배치로 대표 이벤트를 일반 행으로 확정하거나, 서비스 조회용 summary를 만들어 최초 이벤트 변경에 대한 보정 정책을 함께 운영해야 합니다.

여기서 말하는 한계는 dedup 테이블을 읽는 모든 쿼리가 느리다는 뜻은 아닙니다.

- 물리적으로 저장된 state 행 수만 세는 `count()`는 비교적 단순하지만 논리적으로 중복 제거된 정확한 이벤트 수를 보장하지 않습니다.
- 이미 한 행으로 확정된 일반 컬럼을 읽는 dedup 테이블이라면 `argMinMerge` 비용이 없습니다.
- 현재 `AggregatingMergeTree`에는 같은 키의 state가 여러 part에 남을 수 있고 Distributed 조회가 각 shard의 결과를 모으므로, 정확한 최초 이벤트를 얻으려면 조회 시 최종 병합이 필요합니다.
- 중복률이 높아 dedup 후 행 수가 크게 감소하는 데이터에서는 A2의 비용 대비 효과가 달라질 수 있습니다.

현재 결과에 따른 적용 판단은 다음과 같습니다.

| 요구사항 | 적합한 경로 | 판단 |
|---|---|---|
| 전체 누적값을 빠르게 표시, 근사 허용 | event HLL | 현재 데이터에서 가장 빠름. 이벤트별 오차 허용 기준 필요 |
| 분산 상품 1개의 최초 이벤트 정확 집계 | A2 dedup count | 실행 가능하지만 원본 exact 조회보다 느림 |
| 대규모 집중 상품의 최초 이벤트 정확 집계 | A2 dedup count | 현재 구조와 자원에서는 부적합 |
| 반복되는 시간·그룹별 빠른 정확 조회 | dedup 기반 summary | A5·A6에서 우선 검증할 후보 |

A2는 최초 이벤트 상태를 보존하고 필요할 때 정확히 재계산할 수 있다는 장점이 있습니다. 반면 조회 빈도가 높거나 상품 하나의 state가 수백만~천만 단위로 커지면 매 요청의 `argMinMerge`가 병목이 됩니다. 이 경우 A2를 원천 dedup 계층으로 유지하고, 서비스 조회는 미리 계산한 시간별 summary를 사용하는 구조를 검토합니다.
