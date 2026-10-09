# A4 · a4-dedup-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | dedup → exact count |
| 시간·고객 그룹별 | dedup → exact count |
| 생성 흐름 | event → dedup |
| 필요한 저장 대상 | 공통 event 원본, A4 dedup state |
| 독립 DB | `shop_a4` |

## 구현 구조

```text
shop_benchmark.shopping_events (Distributed, 공통 원본)
        ↓ 신규 입력은 local MV / 기존 snapshot은 shard-local backfill
shop_a4.first_event_states_local (ReplicatedAggregatingMergeTree)
        ↓
shop_a4.first_event_states (Distributed)
        ├─ first_events (전체 검증용 View)
        └─ first_events_by_product(product_id) (상품 조회용 parameterized View)
                ├─ 누적 exact count
                ├─ 최초 이벤트 시각 기준 시간별 exact count
                └─ 대표 이벤트 고객 그룹별 exact count
```

A4는 모든 조회를 dedup 상태에서 정확하게 계산합니다. A2와 dedup 방식은 같지만 전체 누적 경로가 다릅니다. A2는 공통 event에서 HLL 근사값을 조회하고, A4는 누적값도 `first_event_states`를 병합해 exact count합니다.

대표 키는 `(product_id, journey_id, event_kind)`입니다. 대표 이벤트는 최소 `received_at`을 사용하고, 수집 시각이 같으면 `message_id` 사전순으로 결정합니다. 같은 `journey_id`가 항상 같은 shard에 있다는 공통 데이터 규칙을 사용합니다.

`first_event_mv`는 INSERT 블록마다 `argMinState`를 만들 뿐, 과거 state를 읽어 하나의 일반 행으로 확정하지 않습니다. background merge가 끝나지 않은 상태에서도 정확한 대표 이벤트를 얻기 위해 조회 시 `argMinMerge`가 필요합니다.

## 파일

| 파일 | 역할 |
|---|---|
| [schema.sql](./schema.sql) | dedup 상태 테이블, Distributed 테이블, local MV와 병합 View 생성 |
| [backfill-from-common.sql](./backfill-from-common.sql) | 한 shard의 공통 원본에서 A4 dedup state 생성 |
| [run-backfill-from-common.sh](./run-backfill-from-common.sh) | shard별 대표 replica를 인자로 받아 순차 backfill |
| [queries.sql](./queries.sql) | 상품별 누적·시간별·고객 그룹별 exact count |
| [check-results.sql](./check-results.sql) | 분산 상품 1개의 공통 기대값 자동 판정 |

## 실행 순서

공통 원본 22,200,000행이 검증된 상태에서 저장소 루트에서 실행합니다.

기본 `manifests/chi.yaml` 배포는 다음 기본값을 그대로 사용합니다. free operator 배포에서는 `export LAB_CLICKHOUSE_POD=clickhouse-0`으로 바꿉니다.

```bash
export LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
```

1. XML 기반 `cluster_internal` 사용자에 A4 권한을 추가합니다.

   ```xml
   <query>GRANT SELECT, INSERT ON shop_a4.*</query>
   ```

   사용자 ConfigMap이 `subPath`로 마운트된 현재 lab에서는 변경 후 ClickHouse StatefulSet을 순차 재시작해야 합니다.

2. A4 객체를 생성합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/cluster/a4-dedup-count/schema.sql
   ```

3. 기존 공통 snapshot을 A4 dedup state로 backfill합니다.

   ```bash
   # 기본 manifests/chi.yaml: 4 shard의 대표 replica가 기본값입니다.
   examples/shopping-journey/cluster/a4-dedup-count/run-backfill-from-common.sh

   # GUIDE(free operator).md: 3 shard의 대표 replica를 명시합니다.
   examples/shopping-journey/cluster/a4-dedup-count/run-backfill-from-common.sh \
     clickhouse-0 clickhouse-3 clickhouse-6
   ```

   스크립트는 기존 state가 한 행이라도 있으면 중단합니다. 인자를 생략하면 기본 Operator 4-shard 대표 Pod인 `chi-chi-cluster1-{0,1,2,3}-0-0`을 사용합니다. 다른 Pod 이름은 위치 인자 또는 `LAB_BACKFILL_PODS`로 전달합니다. backfill은 `max_memory_usage=4GB`, `max_bytes_before_external_group_by=512MiB`를 기본 적용합니다. 여러 shard를 병렬로 처리하면 로컬 kind 메모리 압박이 커지므로 순차 실행합니다.

4. 분산 상품 1개의 공통 기대값을 검증합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     < examples/shopping-journey/cluster/a4-dedup-count/check-results.sql
   ```

5. 상품을 지정해 세 조회를 실행합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     --param_product_id=1000000 \
     < examples/shopping-journey/cluster/a4-dedup-count/queries.sql
   ```

   `1000000`은 journey 100,000개의 분산 상품이고 `2000000`은 journey 10,000,000개의 대규모 집중 상품입니다.

공통 원본에 `first_event_mv`가 연결된 뒤 들어오는 새 event는 A4 state에도 반영됩니다. A1~A7의 적재 성능을 비교할 때는 다른 케이스의 MV를 함께 연결하지 않고 케이스마다 독립적으로 측정해야 합니다.

## 실행 결과

2026-09-21, ClickHouse `26.8.6.5`, `GUIDE(free operator).md`의 별도 3 shard × 3 replica 배포와 공통 원본 snapshot에서 확인했습니다. 저장소 기본 `manifests/chi.yaml`의 4 shard × 3 replica 배포 결과가 아닙니다. 현재 결과는 동시성 1의 [1차 예비 측정](../common/README.md#공통-원본-조회-기준값)입니다.

### backfill과 저장 공간

| 항목 | 결과 |
|---|---:|
| 공통 원본 event | 22,200,000행 |
| 대표 event state | 22,100,000행 |
| shard 1 backfill | 301.578초 |
| shard 2 backfill | 227.117초 |
| shard 3 backfill | 270.208초 |
| 순차 backfill 합계 | 13분 18.903초 |
| backfill 최대 메모리 | shard별 3.45~3.55 GiB |
| dedup state 압축 크기 | 약 755.06 MiB, shard 합계·replica 1벌 기준 |
| 완료 시 replica queue·delay | 0 / 0 |
| backfill 중 Pod 재시작·OOM | 0 |

현재 합성 데이터의 중복 제거율은 약 0.45%이므로 state 행 수가 원본 행 수와 거의 같습니다. A4는 조회에 쓰지 않는 별도 `first_received_at` 열을 두지 않아 동일 snapshot의 A2 state 852.60 MiB보다 작지만, 공통 원본 499.39 MiB보다는 큽니다.

### 정확성

분산 상품 `1000000`의 누적 count와 시간별 count 합계는 모두 기대값과 일치했습니다.

| event_kind | 기대값 | 누적 count | 시간별 합계 |
|---|---:|---:|---:|
| NOTIFY | 100,000 | 100,000 | 100,000 |
| CLICK | 5,000 | 5,000 | 5,000 |
| VIEW | 4,000 | 4,000 | 4,000 |
| CART | 1,000 | 1,000 | 1,000 |
| PURCHASE | 500 | 500 | 500 |

고객 그룹 조회는 36개 결과 그룹과 221,000 membership을 반환했습니다. 대규모 집중 상품의 누적 count도 `NOTIFY 10,000,000`, `CLICK 500,000`, `VIEW 400,000`, `CART 100,000`, `PURCHASE 50,000`으로 기대값과 일치했습니다.

### 조회 성능

| 조회 | 반복 | p50 | p95 | 결과 |
|---|---:|---:|---:|---|
| 분산 상품 1개, 누적 exact count | 10회 | 63ms | 275ms | 성공 |
| 분산 상품 1개, 시간별 exact count | 10회 | 747ms | 888ms | 성공 |
| 분산 상품 1개, 고객 그룹별 exact count | 10회 | 795ms | 1.256초 | 성공 |
| 대규모 집중 상품, 누적 exact count | 5회 | 11.398초 | 19.438초 | 성공, 별도 실행 최대 82.380초 |
| 대규모 집중 상품, 시간별 exact count | 1회 | - | - | 167.656초 후 원격 Pod OOM으로 실패 |
| 대규모 집중 상품, 고객 그룹별 exact count | 0회 | - | - | 시간별 OOM 후 추가 실행 생략 |

집중 상품 누적 조회는 매번 initiator 기준 약 11.07M행·378.77MiB를 읽었고 최대 메모리는 약 578~847MiB였습니다. 같은 쿼리도 6.863초부터 82.380초까지 편차가 컸습니다. active background merge는 없었고 결과 행은 5개뿐이므로 결과 전송보다 분산 state 병합과 로컬 자원 경합의 영향이 큽니다.

집중 상품 시간별 조회 중 `clickhouse-5`가 `OOMKilled`, exit code 137로 재시작되어 원격 EOF가 발생했습니다. Pod 자동 재생성 후 replica queue는 0, 전체 state는 22,100,000행으로 회복됐습니다. 고객 그룹별 조회는 대표 Tuple 복원 후 배열 전개까지 수행하므로 같은 조건에서 OOM 재발 위험이 높아 실행하지 않았습니다.

## A2·A3와 비교

| 경로 | 분산 상품 1개 | 대규모 집중 상품 | 해석 |
|---|---|---|---|
| A2 event HLL | p50 22ms | p50 235ms | 빠른 근사 누적값, 최초 시각·그룹 귀속 불가 |
| A3 event 누적 exact | p50 48ms | p50 3.300초 | 저장 대상 없음, 원본에서 매번 고유 키 계산 |
| A4 dedup 누적 exact | p50 63ms | p50 11.398초 | 정확하지만 state 병합 비용과 저장 공간 발생 |
| A2/A4 dedup 시간별 exact | A2 p50 816ms / A4 p50 747ms | A2 3분 12초 중단 / A4 OOM 실패 | 두 케이스의 상세 경로는 실질적으로 같음 |

A4 누적 쿼리는 대표 Tuple 컬럼을 결과에 사용하지 않으므로 시간·그룹별 조회보다 빠릅니다. 그래도 집중 상품에서는 1,105만 키를 그룹화하고 분산 결과를 병합해야 하므로 A3 원본 누적 exact보다 느렸습니다. dedup 테이블이 존재한다는 사실만으로 조회가 빨라지는 것은 아니며, 현재처럼 중복률이 낮고 aggregate state가 넓으면 저장·병합 비용이 더 커질 수 있습니다.

## 1차 결론과 한계

- 분산 상품 1개 규모에서는 누적·시간·고객 그룹 exact 조회가 모두 약 1.3초 이내 p95로 완료됐습니다.
- 전체 누적도 정확해야 한다면 A4는 A2의 HLL 오차를 제거하지만, 집중 상품 누적 p95가 10초를 넘습니다.
- 대규모 시간별 조회는 167.656초 후 Pod OOM을 일으켜 서비스 요청 경로로 사용할 수 없습니다.
- 현재 데이터는 dedup 후 행 수가 0.45%만 줄어 `argMinState` 저장과 `argMinMerge` 비용을 상쇄하지 못합니다.
- backfill 자체도 shard별 약 3.45~3.55 GiB를 사용하므로 현재 로컬 자원에서 여러 shard를 병렬 실행하면 위험합니다.
- `AggregatingMergeTree`의 물리 `count()`는 아직 합쳐지지 않은 partial state를 중복 집계할 수 있어 정확한 결과에 사용할 수 없습니다.
- `first_events_by_product`는 상품 조건을 상태 병합 내부에 강제합니다. 일반 `first_events` View 바깥의 조건은 전체 state를 먼저 병합할 수 있습니다.
- 실시간 INSERT가 반복되면 snapshot 일괄 backfill보다 partial state와 part가 많아질 수 있으므로 별도 적재·merge 동시 부하 시험이 필요합니다.

A4는 평균 규모 상품의 정확한 저빈도 조회에는 사용할 수 있습니다. 대규모 상품이나 반복되는 시간·그룹별 API 조회에는 dedup state를 매번 병합하지 않는 A5의 summary 구조가 우선 비교 대상입니다.
