# 이벤트 정책별 혼합 Summary 실험

이 실험은 모든 이벤트에 같은 중복 처리 방식을 강제하지 않는다.

| 이벤트 | 대표 이벤트 정책 | 저장·조회 방식 |
|---|---|---|
| `VIEW` | ClickHouse 최초 입수 고정 | `view_first_received`를 직접 `count()` |
| `CLICK` | ClickHouse 최초 입수 고정 | `click_first_received`를 직접 `count()` |
| `CART` | 전체 이력에서 가장 빠른 `occurred_at` | `event_summary_delta`의 signed delta를 `sum()` |
| `PURCHASE` | 전체 이력에서 가장 빠른 `occurred_at` | `event_summary_delta`의 signed delta를 `sum()` |

```text
VIEW raw  ─→ 최초 입수 MV ─→ view_first_received  ─→ count() ─┐
CLICK raw ─→ 최초 입수 MV ─→ click_first_received ─→ count() ─┤
                                                               ├→ hourly_summary_view
CART raw ──→ 최초 시각 비교 MV ─→ event_summary_delta ─→ sum() ┤
PURCHASE raw → 최초 시각 비교 MV → event_summary_delta → sum() ┘
                                                               ↓
                                                        cumulative_summary_view
```

`hourly_summary_view`와 `cumulative_summary_view`는 일반 View다. 별도의
`SummingMergeTree` Summary를 두지 않으며 조회 시 대표 이벤트의 `count()`와
signed delta의 `sum()`을 결합한다.

`*_local_view`는 한 shard의 MV 결과를 검사하고, `_local`이 없는 View는 모든
shard의 Distributed 테이블을 조회하는 애플리케이션용 View다. free-operator의
XML 사용자 `cluster_internal`을 사용하면 분산 View 실행 전에 다음 권한이
필요하다.

```xml
<query>GRANT SELECT ON shop_a7_hybrid.*</query>
```

## 시간 귀속 기준

- 최초 입수 정책은 최초로 입수된 행의 `occurred_at` 시간에 귀속한다.
- 가장 빠른 발생 정책은 현재까지 관측한 최소 `occurred_at` 시간에 귀속한다.
- 더 빠른 발생 이벤트가 늦게 들어오면 이전 시간 `-1`, 새로운 시간 `+1`을 기록한다.

## 실행

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i clickhouse-0 -c clickhouse \
  -- clickhouse-client --multiquery \
  < examples/shopping-journey/cluster/a7-event-replacing_summary-count/hybrid-policy-summary/schema.sql

kubectl --context kind-clickhouse-lab -n clickhouse exec -i clickhouse-0 -c clickhouse \
  -- clickhouse-client --multiquery --format PrettyCompact \
  < examples/shopping-journey/cluster/a7-event-replacing_summary-count/hybrid-policy-summary/check-results.sql
```

## 정확성 경계

증분 MV의 기존 행 확인은 유일성 제약이나 원자적 upsert가 아니다. 서로 다른
INSERT가 같은 논리 키로 정확히 동시에 실행되면 두 요청이 모두 기존 행이 없다고
판단할 수 있다. 이 실험은 한 INSERT 블록 내부 중복과 순차 재입력을 검증하며,
동시 입력 오차는 별도의 보정 검사로 수렴시켜야 한다.

## 1차 검증 결과

2026-10-01, ClickHouse `26.9.4.3`, free-operator 3 shard × 3 replica에서
확인했다.

| 검사 | 기대 | 결과 |
|---|---|---|
| 최초 입수 VIEW | 같은 journey의 후속 입력을 무시하고 1행 | 성공 |
| 최초 입수 CLICK | 같은 journey당 1행 | 성공 |
| 교체형 CART | 11시 `+1` 뒤 11시 `-1`, 09시 `+1` | 성공 |
| 교체형 PURCHASE | 15시 `+1` 뒤 15시 `-1`, 14시 `+1` | 성공 |
| 시간별 통합 View | 09시 CART 1, 10시 VIEW·CLICK 1, 14시 PURCHASE 1 | 성공 |
| 누적 통합 View | VIEW·CART·CLICK·PURCHASE 각각 1 | 성공 |

DDL과 shard-local 정확성 검사는 통과했다. 애플리케이션용 분산 View는 현재
free-operator의 `cluster_internal` 사용자에게 새 데이터베이스의 `SELECT`
권한이 없어서 실행하지 않았다. 위 권한을 추가한 뒤 같은 결과가 3개 shard에서
합쳐지는지 별도로 확인해야 한다.

## Delta와 ReplacingMergeTree 1차 성능 비교

단일 shard에서 다음 세 경로를 동일한 데이터로 비교했다. 클러스터 네트워크와
replica 복제 비용을 제외하고 엔진·MV 계산 차이를 보는 실험이다.

| 경로 | 적재 후 대표값 생성 | 조회 |
|---|---|---|
| Direct | 최초 입수 후보만 일반 `MergeTree`에 저장 | `count()` |
| Replacing | 모든 후보를 `ReplacingMergeTree`에 저장 | `FINAL count()` |
| Delta | 최초 시각 변화의 signed delta 저장 | `sum(count_delta)` |

테스트 데이터는 물리 이벤트 1,000,000행, 논리 journey 100,000개, journey당
중복 후보 10개, 집중 상품 1개다. 적재는 각 경로의 원본 `MergeTree`와 MV를
모두 통과한 완료 시간이다.

| 경로 | 적재 시간 | 적재된 집계 행 |
|---|---:|---:|
| Direct | 10.192초 | 대표 100,000행 |
| Replacing, insert-time 정리 | 2.066초 | 대표 100,000행 |
| Replacing, 후보 미정리 | 1.224초 | 후보 1,000,000행 |
| Delta | 18.446초 | delta 100,000행 |

Replacing은 기존 상태를 조회하지 않고 후보를 그대로 쓰므로 적재가 가장
빠르다. Direct는 현재 block 집계와 기존 대표 키 확인, Delta는 현재 block
집계와 전체 이력의 동일 키·최소 시각 비교가 들어가 적재 비용이 커졌다.

각 쿼리를 동시성 1로 100회 반복한 안정화 후 결과는 다음과 같다.

| 상태·조회 | p50 | p95 |
|---|---:|---:|
| Direct 누적 `count()` | 3ms | 9ms |
| Delta 누적 `sum(count_delta)` | 4ms | 16ms |
| Replacing 병합 후 `FINAL count()` | 1ms | 6ms |
| Replacing 병합 전 `FINAL count()` | 15ms | 47ms |
| Direct 시간별 `count() GROUP BY` | 4ms | 21ms |
| Delta 시간별 `sum(delta) GROUP BY` | 2ms | 7ms |
| Replacing 병합 후 시간별 `FINAL GROUP BY` | 3ms | 12ms |
| Replacing 병합 전 시간별 `FINAL GROUP BY` | 32ms | 145ms |

첫 측정 라운드에는 background 작업 영향으로 병합 전 Replacing 누적 p50
41ms, p95 187ms까지 관측됐다. 위 표의 누적값은 안정화 후 두 번째 라운드이고,
시간별 값은 merge를 중지한 100만 물리 후보 상태의 100회 결과다.

물리 저장량은 이 데이터에서 Delta 9.03KiB, Direct 402.08KiB, 병합 후
Replacing 406.35KiB, 병합 전 Replacing 1.15MiB였다. Delta는 동일 상품·시간의
정수 열이 잘 압축된 결과이며 상품·시간 cardinality가 늘면 함께 증가한다.

### 해석

- 대표 이벤트가 바뀌지 않는 정책은 Direct가 단순하고 누적·시간 조회도 충분히 빠르다.
- Replacing은 쓰기가 가장 빠르고 merge가 따라잡으면 조회도 가장 빠른 수준이었다.
- Replacing의 위험은 엔진 자체의 상시 비용보다, 작은 INSERT와 중복 폭증으로 merge가 밀릴 때 `FINAL`이 아직 남은 모든 후보를 정리해야 한다는 점이다.
- Delta는 적재 판정 비용이 가장 크지만 시간별 귀속 이동을 즉시 반영하고 시간별 조회가 가장 안정적으로 빨랐다.
- 따라서 최초 입수 고정 이벤트는 Direct, 교체 빈도가 낮고 merge 여유가 있는 이벤트는 Replacing, 시간 귀속 변경을 즉시 정확하게 제공해야 하는 이벤트는 Delta가 적합하다.

재현 파일은 [`benchmark`](./benchmark/) 디렉터리에 있다. 이 수치는 로컬
단일 shard의 1차 비교값이며 최종 선택 전에는 실제 batch 크기, 동시 INSERT,
merge backlog와 집중 상품의 논리 journey 100만 이상을 추가 측정해야 한다.

## 1억 원본·tracking당 100행 비교

실제 조회 범위에 가까운 다음 조건으로 추가 측정했다. 재현 DDL과 생성 쿼리는
[`benchmark-100m`](./benchmark-100m/)에 있다.

| 조건 | 값 |
|---|---:|
| 원본 이벤트 | 100,000,000행 |
| 논리 tracking ID | 1,000,000개 |
| tracking ID별 기존 이력 | 정확히 100행 |
| 상품 | 집중 상품 1개 |
| 신규 입력 | 기존 tracking ID에 더 빠른 발생 시각 1행 |
| 단건 INSERT 반복 | 방식별 100회, 동시성 1 |

원본 1억 행은 473.304초에 생성됐고 디스크에서 131.33MiB를 사용했다. 초기
Direct 대표 100만 행은 3.93MiB, Delta 100만 행은 90.14KiB였다. merge를
중지한 Replacing 후보 1억 행은 42.90MiB였다.

### 단건 INSERT

각 INSERT는 임의의 기존 tracking ID를 선택한다. 따라서 Direct는 이미 승인된
대표가 있는지 확인하고 무시하며, Delta는 기존 100행의 최소 시각과 비교해
이전 시간 `-1`·신규 시간 `+1`을 기록하고, Replacing은 새 후보를 추가한다.

| 방식 | p50 | p95 | INSERT당 평균 읽은 행 |
|---|---:|---:|---:|
| Direct | 9~10ms | 31ms | 8,195행 |
| Delta | 11~13ms | 40~41ms | 8,277행 |
| Replacing | 11~13ms | 27~29ms | 2행 |

Direct와 Delta가 원본 1억 행을 모두 읽지는 않았다. 정렬 키
`(product_id, tracking_id, ...)`와 현재 후보 키 필터로 해당 sparse-index
granule 약 8,192행을 읽고 그 안의 동일 tracking 이력 100행을 비교했다.
Delta 100회는 시간 이동마다 두 행을 기록해 `delta_log`가 1,000,200행이
됐지만, 합계는 계속 1,000,000으로 유지됐다.

### 누적·시간별 조회

| 상태·조회 | 반복 | p50 | p95 |
|---|---:|---:|---:|
| Direct 누적 `count()` | 100회 | 2ms | 21ms |
| Delta 누적 `sum(count_delta)` | 100회 | 8ms | 46ms |
| Replacing merge 전 누적 `FINAL count()` | 단일 | 5.338초 | - |
| Replacing merge 전 누적 `FINAL count()` | 5회 연속 | 13.698초 | 19.838초 |
| Direct 시간별 `GROUP BY` | 100회 | 5ms | 13ms |
| Delta 시간별 `GROUP BY` | 100회 | 6ms | 27ms |
| Replacing merge 전 시간별 `FINAL GROUP BY` | 단일 | 4.331초 | - |
| Replacing merge 후 누적 `FINAL count()` | 100회 | 3ms | 10ms |
| Replacing merge 후 시간별 `FINAL GROUP BY` | 100회 | 7ms | 17ms |

이 실험에서는 하나의 정렬된 1억 행 part를 `OPTIMIZE FINAL`로 정리하는 데
2.768초가 걸렸고, Replacing은 100만 대표 행·3.97MiB로 줄었다. 운영에서
다수의 작은 part, 동시 INSERT와 background merge가 경쟁하면 같은 시간을
보장하지 않는다.

### 1억 조건 결론

- 신규 한 건의 판정 시간은 전체 1억 행보다 정렬 키와 같은 tracking ID가 놓인 index granule 크기에 좌우됐다.
- 세 방식 모두 단건 p50 9~13ms, p95 27~41ms로 큰 차이가 없었다.
- 조회는 Direct와 Delta가 50ms 안쪽이었지만, 1억 후보가 미병합된 Replacing은 4~20초가 걸려 1초 목표를 넘었다.
- Replacing이 100만 대표 행으로 merge된 뒤에는 다시 p50 3~7ms로 회복했다.
- 따라서 Replacing 채택 여부는 평균 중복 100건 자체보다 **background merge가 조회 전에 후보를 충분히 소거할 수 있는지**로 결정해야 한다.
