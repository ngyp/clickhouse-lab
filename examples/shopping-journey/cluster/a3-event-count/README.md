# A3 · a3-event-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | event → 최초 키 선별 → exact count |
| 시간·고객 그룹별 | event → 최초 이벤트 선별 → exact count |
| 생성 흐름 | event에서 조회 시 dedup·count |
| 필요한 저장 대상 | 공통 event 원본만 사용 |
| 독립 DB | `shop_a3`, 저장 테이블 없이 View만 생성 |

## 구현 구조

```text
shop_benchmark.shopping_events_local (각 shard의 원본)
        ├─ event_counts_local View
        ├─ hourly_counts_local View
        └─ customer_group_counts_local View
                    ↓ shard별 소수의 count 결과
             Distributed 조회 객체
                    ↓ sum(exact_count)
              최종 exact count
```

A3는 dedup·summary 데이터를 별도로 저장하지 않습니다. 요청이 들어올 때마다 각 shard의 원본에서 `(product_id, journey_id, event_kind)`를 선별하고 exact count를 계산합니다.

처음에는 Distributed 원본에서 최초 이벤트 1,105만 개를 coordinator로 모아 최종 집계했습니다. 분산 상품 1개는 처리됐지만 대규모 집중 상품은 약 3 GiB의 메모리를 사용한 뒤 실패했습니다. 최종 구현은 일반 View가 각 shard에서 최초 이벤트와 count까지 계산하고 coordinator는 shard별 count만 더합니다.

이 구조가 정확하려면 같은 `journey_id`가 항상 같은 shard에 있어야 합니다. 공통 원본은 `cityHash64(journey_id)`로 분산되므로 조건을 만족합니다. 로컬 테이블에 직접 입력해 같은 journey가 여러 shard에 나뉘면 shard별 선별 결과를 더하는 A3 결과가 중복될 수 있습니다.

## 조회별 선별 범위

조회에 필요하지 않은 대표 속성을 `argMin` Tuple에 포함하면 메모리 사용량이 커집니다. A3는 경로별로 필요한 컬럼만 선별합니다.

| 조회 | 최초 선별 시 보존하는 값 |
|---|---|
| 전체 누적 | 속성 불필요, 고유 `(journey_id, event_kind)`만 선별 |
| 시간별 | `occurred_at` |
| 고객 그룹별 | `mall_id`, `store_id`, `customer_group_ids` |

대표 이벤트는 공통 기준과 동일하게 최소 `received_at`을 사용하고, 수집 시각이 같으면 `message_id` 사전순으로 결정합니다. 시간별 결과는 선택된 대표 이벤트의 `occurred_at`에 귀속합니다.

## 파일

| 파일 | 역할 |
|---|---|
| [schema.sql](./schema.sql) | shard-local 집계 View와 Distributed 조회 객체 생성 |
| [queries.sql](./queries.sql) | 상품별 누적·시간별·고객 그룹별 exact count |
| [check-results.sql](./check-results.sql) | 분산 상품 1개의 기대 count 자동 판정 |

## 실행 순서

공통 데이터 22,200,000행이 검증된 상태에서 저장소 루트에서 실행합니다.

기본 `manifests/chi.yaml` 배포는 다음 기본값을 그대로 사용합니다. free operator 배포에서는 `export LAB_CLICKHOUSE_POD=clickhouse-0`으로 바꿉니다.

```bash
export LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
```

1. `cluster_internal` 사용자에 다음 권한을 추가합니다.

   ```xml
   <query>GRANT SELECT ON shop_a3.*</query>
   ```

   XML 사용자 설정을 변경했다면 ClickHouse StatefulSet을 순차 재시작합니다.

2. A3 View를 생성합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/cluster/a3-event-count/schema.sql
   ```

3. 분산 상품 1개의 기대 결과를 검증합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     < examples/shopping-journey/cluster/a3-event-count/check-results.sql
   ```

4. 상품을 지정해 세 조회를 실행합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     --param_product_id=1000000 \
     < examples/shopping-journey/cluster/a3-event-count/queries.sql
   ```

   `1000000`은 journey 100,000개의 분산 상품이고 `2000000`은 journey 10,000,000개의 대규모 집중 상품입니다.

## 실행 결과

2026-09-21, ClickHouse `26.8.6.5`, `GUIDE(free operator).md`의 별도 3 shard × 3 replica 배포와 공통 원본 snapshot에서 확인했습니다. 저장소 기본 `manifests/chi.yaml`의 4 shard × 3 replica 배포 결과가 아닙니다. 현재 결과는 동시성 1의 [1차 예비 측정](../common/README.md#공통-원본-조회-기준값)입니다.

### 정확성

분산 상품 `1000000`의 누적 count와 시간별 count 합계는 모두 기대값과 일치했습니다.

| event_kind | 기대값 | 누적 count | 시간별 합계 |
|---|---:|---:|---:|
| NOTIFY | 100,000 | 100,000 | 100,000 |
| CLICK | 5,000 | 5,000 | 5,000 |
| VIEW | 4,000 | 4,000 | 4,000 |
| CART | 1,000 | 1,000 | 1,000 |
| PURCHASE | 500 | 500 | 500 |

고객 그룹 조회는 36개 결과 그룹과 221,000 membership을 반환했습니다. 대표 이벤트 110,500개가 서로 다른 고객 그룹 두 개에 속하는 입력 규칙과 일치합니다.

대규모 집중 상품의 누적 exact count도 `NOTIFY 10,000,000`, `CLICK 500,000`, `VIEW 400,000`, `CART 100,000`, `PURCHASE 50,000`으로 기대값과 일치했습니다.

### 성능

| 조회 | 반복 | p50 | p95 | 결과 |
|---|---:|---:|---:|---|
| 분산 상품 1개, 누적 exact count | 10회 | 48ms | 429ms | 성공 |
| 분산 상품 1개, 시간별 exact count | 10회 | 159ms | 472ms | 성공 |
| 분산 상품 1개, 고객 그룹별 exact count | 10회 | 138ms | 329ms | 성공 |
| 대규모 집중 상품, 누적 exact count | 5회 | 3.300초 | 7.263초 | 성공 |
| 대규모 집중 상품, 시간별 exact count | 1회 | - | - | 73.234초, 성공 |
| 대규모 집중 상품, 고객 그룹별 exact count | 1회 | - | - | 93.678초, 성공 |

대규모 시간별 조회는 원본 11.12 million행·844.65 MiB를 읽었고 initiator의 query log 기준 최대 메모리는 386.99 MiB였습니다. 결과는 3,360행이었습니다. 고객 그룹별 조회는 11.12 million행·1.16 GiB를 읽었고 initiator 기준 최대 메모리는 608.34 MiB였습니다.

### coordinator 직접 집계와 비교

Distributed 원본에서 대표 이벤트를 모두 만든 뒤 coordinator가 시간별 집계를 수행하는 초기 쿼리는 대규모 집중 상품에서 실패했습니다.

| 방식 | 결과 |
|---|---|
| coordinator에서 1,105만 대표 이벤트 병합 | 약 3 GiB 메모리 한도 초과 |
| 512 MiB 외부 집계 설정 | 41.734초 후 전체 노드 메모리 압박으로 종료 |
| shard-local 시간별 View 후 작은 결과 합산 | 73.234초에 완료, initiator 386.99 MiB |

shard-local 집계는 빠른 API 응답을 만들지는 못했지만, coordinator의 메모리 초과를 피하고 대규모 exact 조회를 완료 가능한 작업으로 바꿨습니다.

## 1차 결론과 한계

- 별도 dedup 저장소가 없어 저장 공간과 적재 시 MV 비용이 추가되지 않습니다.
- 항상 원본을 다시 읽으므로 데이터가 커질수록 CPU·디스크 비용이 반복됩니다.
- 분산 상품 1개 규모에서는 세 exact 조회가 모두 0.5초 이내 p95로 동작했습니다.
- 대규모 집중 상품의 누적 count는 완료되지만 p95 7초대로 실시간 API 목표를 정하기 어렵습니다.
- 대규모 시간·고객 그룹별 조회는 1분 이상 걸리므로 서비스 요청 경로로 부적합합니다.
- shard-local 결과 합산은 `journey_id`가 shard 사이에 겹치지 않는다는 분산 규칙에 의존합니다.
- 조회 View의 `product_id` 조건이 로컬 원본까지 내려가는지 ClickHouse 버전 변경 후 실행 계획과 읽은 행 수를 다시 확인해야 합니다.

A3는 파생 데이터 없이 정확한 값을 재계산해야 하는 검증·저빈도 배치 조회에 사용할 수 있습니다. 반복되는 서비스 조회는 A2의 dedup 상태 또는 A5·A6의 summary와 비교해 결정해야 하며, 이번 결과에서는 대규모 시간·그룹 조회용으로 summary가 우선 후보입니다.

## 10초 API timeout과 전체 데이터 증가 해석

현재 대규모 집중 상품은 실제 구조의 tracking ID에 대응하는 journey 10,000,000개를 가집니다. 합성 데이터의 반응률을 적용한 원본은 11,100,000행입니다.

| 조회 | 현재 결과 | 10초 timeout 해석 |
|---|---:|---|
| 이벤트 종류별 누적 count | p50 3.300초, p95 7.263초 | 가능성은 있지만 운영 여유가 작음 |
| 시간별 count | 73.234초 | 사용 불가 |
| 고객 그룹별 count | 93.678초 | 사용 불가 |

누적 count만 보면 10초 안에 완료됐지만 5회·동시성 1의 예비 결과입니다. 네트워크, 동시 요청, merge와 적재 작업을 고려하면 10초 timeout을 그대로 성능 목표로 사용하지 않습니다. 10초 API의 1차 합격 후보는 목표 동시성에서 `p95 ≤ 5초`, `p99 < 10초`, timeout·메모리 오류 0건으로 두고 실제 운영 자원에서 검증합니다.

전체 원본이 10억 행으로 늘어도 `placement_id`에 대응하는 `product_id` 조건이 1,000만 tracking ID 범위를 정확히 좁히면 10억 행 전체를 집계하지는 않습니다. 공통 원본의 정렬 키가 `(product_id, journey_id, event_kind, ...)`이므로 `WHERE product_id = ?`가 관련 mark를 우선 읽도록 구성돼 있습니다.

하지만 전체 크기가 완전히 무관해지는 것은 아닙니다.

- 보존 기간이 길어지면 같은 상품 데이터가 더 많은 월 partition과 part에 흩어질 수 있습니다.
- part 수, merge backlog와 page cache 상태에 따라 같은 1,000만 행의 읽기 비용도 달라집니다.
- `product_id`를 직접 조건으로 사용하지 않고 큰 `id_map` JOIN으로 찾으면 index pruning과 JOIN 비용을 다시 검증해야 합니다.
- tracking ID 1,000만 개에 모든 이벤트 종류가 존재하면 현재 반응률 기반 1,110만 행보다 훨씬 많은 원본을 읽습니다. 이벤트 4종이 모두 한 번씩만 있어도 4,000만 행입니다.
- 여러 placement를 한 요청에서 조회하면 각 placement의 대상 행 수가 합산됩니다.

따라서 운영 검증 데이터는 전체 보존량, 대상 placement의 tracking ID 수, event 반응률·중복률을 각각 독립 축으로 늘려야 합니다.
