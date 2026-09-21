# A5 · a5-dedup_summary-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | dedup → summary → count |
| 시간·고객 그룹별 | dedup → summary → count |
| 생성 흐름 | event → dedup → summary |
| 저장 대상 | event, dedup, 상품별·그룹별 summary |
| 독립 DB | `shop_a5` |

## 검증하려는 것

A2는 조회할 때마다 `argMinMerge`로 대표 이벤트를 확정합니다. 집중 상품처럼 대상 state가 수백만 건이면 이 병합이 병목이 됩니다. A5는 대표 이벤트에서 미리 exact summary를 만들고 서비스 조회가 작은 summary만 읽도록 합니다.

다음 두 조건을 모두 만족해야 A5를 통과한 것으로 판단합니다.

1. summary 조회가 일반 상품, 집중 상품, 전체 누적, 고객 그룹 조건에서 정확하고 빠르다.
2. 동일 메시지 재전송과 더 이른 대표 이벤트의 지연 도착 때 기존 bucket을 빼고 새 bucket을 더한다.

## 구현 구조

```text
shopping_events (Distributed, journey_id sharding)
        ↓ local MV
first_event_states_local (ReplicatedAggregatingMergeTree)
        ↓ 대표 이벤트 확정
        ├─ event_summary_local
        └─ customer_group_summary_local
                 ↓
       Distributed summary 조회
```

`event_summary`는 상품·시간·이벤트 종류별 exact count를 저장합니다. `customer_group_summary`는 대표 이벤트의 `customer_group_ids`를 중복 제거하고 전개한 뒤 상품·시간·고객 그룹·이벤트 종류별 count를 저장합니다.

summary의 `event_count`는 대표 변경 보정에서 `-1`과 `+1` delta를 모두 받을 수 있도록 `Int64`로 정의했습니다. 현재 구현은 검증된 공통 snapshot에서 dedup과 summary를 만드는 backfill까지 제공합니다. 실시간 보정 writer는 구현하지 않았습니다.

## 파일

| 파일 | 내용 |
|---|---|
| [schema.sql](./schema.sql) | Replicated event·dedup·summary 테이블과 Distributed 테이블 |
| [backfill-dedup-from-common.sql](./backfill-dedup-from-common.sql) | 공통 원본에서 shard 로컬 dedup state 생성 |
| [backfill-summary.sql](./backfill-summary.sql) | shard 로컬 dedup에서 두 summary 생성 |
| [run-backfill-from-common.sh](./run-backfill-from-common.sh) | 실제 shard 수를 조회해 대표 replica에서 순차 backfill |
| [validate.sql](./validate.sql) | 전체·이벤트별·일반/집중 상품·고객 그룹 정합성과 복제 상태 검증 |
| [test-naive-realtime-limit.sql](./test-naive-realtime-limit.sql) | 단순 chained MV의 재전송·대표 변경 오집계 재현 |
| [run-summary-latency-test.sh](./run-summary-latency-test.sh) | incremental chained MV의 insert-to-summary 지연 측정 |
| [test-summary-latency-schema.sql](./test-summary-latency-schema.sql) | chained MV 지연 측정용 단일 노드 schema |
| [run-refresh-latency-test.sh](./run-refresh-latency-test.sh) | exact summary를 새 replicated target에 shard 병렬 재생성 |
| [test-refresh-schema.sql](./test-refresh-schema.sql) | periodic refresh 측정용 replicated target schema |
| [test-refresh-backfill-local.sql](./test-refresh-backfill-local.sql) | shard 로컬 exact summary 전체 재생성 query |
| [correction-design.md](./correction-design.md) | 실시간 대표 변경 보정, 멱등성, 복구·모니터링과 구현 작업 |

## 실행

공통 원본을 먼저 만들고 검증합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery \
  < examples/shopping-journey/cluster/common/schema.sql

LAB_CLICKHOUSE_POD=chi-chi-cluster1-0-0-0 \
  examples/shopping-journey/cluster/common/run-generate-data.sh
```

A5 스키마와 snapshot을 생성합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery \
  < examples/shopping-journey/cluster/a5-dedup_summary-count/schema.sql

examples/shopping-journey/cluster/a5-dedup_summary-count/run-backfill-from-common.sh
```

정합성과 단순 실시간 MV의 한계를 확인합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery --format PrettyCompact \
  < examples/shopping-journey/cluster/a5-dedup_summary-count/validate.sql

kubectl --context kind-clickhouse-lab -n clickhouse exec -i \
  chi-chi-cluster1-0-0-0 -c clickhouse -- \
  clickhouse-client --multiquery --format PrettyCompact \
  < examples/shopping-journey/cluster/a5-dedup_summary-count/test-naive-realtime-limit.sql
```

## 실행 결과

2026-09-21, ClickHouse `26.9.1.1357`, 4 shard × 3 replica에서 공통 원본 22,200,000행을 사용했습니다. 일반 상품은 100개×100,000 journey이고 집중 상품은 1개×10,000,000 journey입니다.

### snapshot 생성과 정합성

| 항목 | 결과 |
|---|---:|
| dedup 대표 state | 22,100,000행 |
| 이벤트 summary 물리 행 | 70,549행 |
| 고객 그룹 summary 물리 행 | 508,895행 |
| 이벤트 exact 합계 | 22,100,000, 기대값 일치 |
| 고객 그룹 귀속 합계 | 44,200,000, 기대값 일치 |
| 일반·집중 상품 event별 count | 모두 기대값 일치 |
| replica queue / delay | 0 / 0 |

각 shard를 순차 처리한 query 시간의 합은 dedup 약 65.6초, 이벤트 summary 약 29.0초, 고객 그룹 summary 약 22.4초였습니다. 압축 저장 크기는 replica 한 벌과 전체 shard 합계 기준으로 dedup 392.77 MiB, 이벤트 summary 272.75 KiB, 고객 그룹 summary 1.69 MiB였습니다.

제한 없는 현재 배포 설정에서 query log의 최대 메모리는 dedup 3.56 GiB, 이벤트 summary 2.39 GiB, 고객 그룹 summary 2.54 GiB였습니다. 고객 그룹 계산을 manifest의 배치 설정과 같은 `max_memory_usage=2GB`, `max_bytes_before_external_group_by=50MB`로 다시 실행하면 5.94초, 최대 943.33 MiB로 완료했고 304.89 MiB를 외부 집계로 spill했습니다.

현재 실행 중인 Pod에는 저장소의 `batch_user`와 `realtime_user`가 생성되어 있지 않고 기본 계정의 메모리 제한도 0입니다. manifest 변경이 현재 클러스터에 반영되지 않은 상태이므로 운영 조건 성능으로 해석하면 안 됩니다.

### summary 조회 성능

각 조회는 단일 동시성으로 105회 실행했습니다. 시간은 서버 처리 시간입니다.

| 조회 | p50 | p95 | p99 |
|---|---:|---:|---:|
| 일반 상품 1개 시간별 exact | 3ms | 4ms | 5ms |
| 집중 상품 1개 시간별 exact | 6ms | 22ms | 56ms |
| 전체 데이터셋 event별 exact | 2ms | 3ms | 5ms |
| 집중 상품 1개 시간·고객그룹별 exact | 4ms | 5ms | 6ms |

A2에서 같은 집중 상품의 dedup 직접 count는 3분 12초 안에 끝나지 않았습니다. A5 snapshot summary는 이 조회 병목을 제거했습니다.

### 단일 replica 장애

`chi-chi-cluster1-0-2-0` Pod를 삭제하고 재생성되는 동안 집중 상품 summary 조회를 동시성 4로 2,000회 실행했습니다.

| 항목 | 결과 |
|---|---:|
| 성공 / 실패 | 2,000 / 0 |
| 장애 중 p50 / p95 / p99 | 9ms / 30ms / 53ms |
| 새 Pod 생성 → Ready | 10초 |
| 복구 후 replica queue / delay | 0 / 0 |
| 복구 후 exact 결과 | 변경 없음 |

이 결과는 단일 replica 읽기 장애만 검증합니다. 적재 중 장애, shard 전체 장애, Keeper 장애는 아직 실행하지 않았습니다.

### 실시간 보정 판정

단순 chained MV를 실제로 구성해 같은 이벤트를 재전송하고, 더 이른 대표 이벤트를 뒤늦게 넣었습니다.

| 항목 | 기대 | 실제 |
|---|---:|---:|
| 원본 행 | 3 | 3 |
| dedup 논리 대표 | 1 | 1 |
| 대표 시간 | 09시 | 09시 |
| summary 합계 | 1 | 3 |
| 10시 이전 bucket | 0 | 2 |

MV는 새 INSERT block만 보기 때문에 재전송 때 기존 summary를 다시 더했고, 대표가 10시에서 09시로 바뀔 때 10시 bucket을 빼지 못했습니다. 따라서 `event → dedup MV → count MV`만 연결한 구현은 A5가 요구하는 exact 실시간 summary가 아닙니다.

### summary 갱신 방식과 실제 지연

ClickHouse에는 서로 다른 두 MV 방식이 있습니다.

- [Incremental Materialized View](https://clickhouse.com/docs/concepts/features/materialized-views/incremental-materialized-view)는 source INSERT block을 즉시 처리합니다. 변환 비용은 INSERT에 포함되고, INSERT가 성공한 직후 target 결과를 조회할 수 있습니다.
- [Refreshable Materialized View](https://clickhouse.com/docs/concepts/features/materialized-views/refreshable-materialized-view)는 전체 query를 정해진 주기로 다시 실행하고 결과를 교체합니다. 일정 수준의 stale 결과를 허용할 때 사용합니다.

현재 A5 schema는 `event → dedup`만 incremental MV입니다. `dedup → summary`는 snapshot backfill이며 자동 갱신되지 않습니다. 현재 `backfill-summary.sql`을 같은 target에 다시 실행하면 `SummingMergeTree`에 기존 count가 다시 더해지므로 주기 작업으로 그대로 사용하면 안 됩니다.

#### incremental chained MV

단일 노드 임시 DB에서 `event → dedup MV → naive summary MV`를 만들고 동기 INSERT 시간을 측정했습니다. 서버 처리 시간이며 동시성 1입니다.

| 입력 | 반복 | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| MV 없는 1행 INSERT | 105 | 1ms | 2ms | 3ms |
| chained MV 1행 INSERT | 105 | 3ms | 5ms | 6ms |
| chained MV 1,000행 batch | 30 | 9ms | 14ms | 23ms |
| chained MV 100,000행 batch | 10 | 276ms | 382ms | 382ms |

INSERT 성공 직후 실행한 첫 SELECT에서 summary가 바로 확인됐습니다. 따라서 이 실험에서 별도의 post-insert refresh 지연은 관측되지 않았고, event-to-summary 가시성은 INSERT 응답 시간 안에 포함됐습니다.

하지만 이 경로는 빠르더라도 exact A5가 아닙니다. 같은 business event의 재전송과 더 이른 대표 이벤트의 지연 도착을 처리할 이전 상태가 없어 summary를 중복 가산합니다. upstream이 이미 확정한 대표 이벤트나 멱등 correction delta만 source에 넣는 구조일 때만 incremental summary MV를 사용할 수 있습니다.

#### exact periodic refresh

현재 22,100,000개 dedup state에서 이벤트·고객 그룹 summary를 빈 replicated target에 다시 만들었습니다. 4개 shard의 대표 replica에서 병렬 실행했고, `max_memory_usage=2GB`, `max_bytes_before_external_group_by=50MB`를 적용했습니다.

| 항목 | 결과 |
|---|---:|
| 전체 refresh 벽시계 시간 | 49초 |
| 이벤트 exact 합계 | 22,100,000, 기대값 일치 |
| 고객 그룹 귀속 합계 | 44,200,000, 기대값 일치 |
| shard별 최대 메모리 | 949.91 MiB |
| shard별 event summary spill | 약 246 MiB |
| shard별 group summary spill | 약 284~288 MiB |
| 완료 후 replica queue / delay | 0 / 0 |

샤드별 이벤트 summary는 20.2~31.7초, 고객 그룹 summary는 15.4~19.4초 걸렸습니다. 각 shard에서 두 query를 순차 실행했으며 가장 느린 shard가 전체 49초를 결정했습니다.

refresh 간격을 `I`, 실제 실행 시간을 `R`이라고 하면 snapshot에 포함된 이벤트가 서비스 target에 보이기까지의 지연 범위는 대략 다음과 같습니다.

```text
R ≤ freshness lag < I + R
```

이번 측정의 `R=49초`를 적용하면 다음과 같습니다.

| refresh 간격 | 최소 지연 | 최악 지연 | 실행 여유 |
|---|---:|---:|---:|
| 1분 | 약 49초 | 약 109초 | 약 11초 |
| 5분 | 약 49초 | 약 349초 | 약 251초 |

1분보다 짧은 주기는 현재 실행 시간보다 짧아 refresh가 밀리거나 계속 실행되는 상태가 됩니다. 운영에서는 새 shadow target을 완성하고 정합성을 확인한 뒤 서비스 target과 교체해야 합니다. 이번 테스트는 shadow target 생성·복제 완료까지 측정했으며 metadata 교체는 포함하지 않았습니다.

#### 선택 기준

| 요구사항 | 방식 | 예상 지연 | 현재 판정 |
|---|---|---:|---|
| 수분 stale 허용, exact 필요 | periodic full refresh | 1분 주기에서 약 49~109초 | 구현 가능, 주기적 재계산 경로 |
| 수 ms~수백 ms, upstream이 대표·보정 확정 | incremental summary MV | INSERT p50 3ms부터 batch 크기에 비례 | 사용 가능 |
| 수초 이하, raw event에서 exact 대표 변경 | stateful correction processor + summary delta | processor lag + batch + INSERT | 미구현, A5 목표 경로 |

주기적 full refresh는 현재 데이터 규모에서 현실적인 임시안입니다. 다만 이 저장소가 정의한 A5의 실시간 요구를 충족한 것으로 보지는 않습니다. 실시간 exact가 필요하면 [보정 설계](./correction-design.md)의 상태 처리기와 멱등 sink를 구현해야 합니다.

## 판정

| 검증 항목 | 판정 |
|---|---|
| snapshot exact 정합성 | 통과 |
| 일반·집중 상품 summary 조회 성능 | 통과 |
| 단일 replica 읽기 연속성과 복구 | 통과 |
| 동일 메시지 재시도 멱등성 | 실패 |
| 지연 도착 대표 변경 보정 | 실패 |
| A5 전체 운영 준비 | 미통과 |

서비스 조회용 summary 자체는 효과가 큽니다. 프로덕션 A5가 되려면 이전 대표를 기억하는 상태 처리기가 각 변경에 대해 이전 bucket `-1`, 새 bucket `+1`을 멱등하게 기록해야 합니다. 또한 checkpoint와 재시작 replay, correction 처리 실패 큐, event 입력부터 summary 반영까지의 지연 지표가 필요합니다. 구체적인 처리 계약, 전환 절차, 필수 테스트와 작업 순서는 [실시간 보정 구현 보완사항](./correction-design.md)에 정리했습니다. 이 처리 방식이 구현되기 전에는 snapshot backfill 또는 주기적 재계산 결과만 사용할 수 있으며, 이 저장소의 실시간 요구사항을 충족한 것으로 보지 않습니다.
