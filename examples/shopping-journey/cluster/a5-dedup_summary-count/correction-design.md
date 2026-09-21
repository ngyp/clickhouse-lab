# A5 실시간 보정 구현 보완사항

[A5 실행 결과](./README.md) · [데이터 결과 기준](../../expected/data-result.md) · [가용성·복구 기준](../../expected/availability-recovery.md)

## 목적

A5 summary는 `(product_id, journey_id, event_kind)`별 최초 대표 이벤트가 바뀔 때 이전 집계값을 제거하고 새 집계값을 반영해야 합니다. 동일 이벤트와 동일 correction이 재처리되더라도 최종 count는 한 번 처리한 결과와 같아야 합니다.

단순 chained Materialized View는 INSERT block 안의 데이터만 보므로 이전 대표를 알 수 없습니다. `SummingMergeTree`도 전달받은 delta를 합산할 뿐 같은 correction을 자동으로 한 번만 적용하지 않습니다. 따라서 대표 상태와 correction 적용 상태를 함께 관리하는 처리 계층이 필요합니다.

## 불변 규칙

| 항목 | 규칙 |
|---|---|
| dedup key | `(product_id, journey_id, event_kind)` |
| 대표 선택 | `(received_at, message_id)`가 사전순으로 가장 작은 이벤트 |
| 시간 bucket | 대표 이벤트의 `occurred_at`을 UTC 시간 단위로 절삭 |
| 고객 그룹 | 대표 이벤트의 `customer_group_ids`를 중복 제거한 뒤 전개 |
| correction | 이전 bucket `-1`, 새 bucket `+1` |
| 재처리 | 같은 입력과 correction을 반복해도 최종 결과 불변 |
| 순서 보장 | 같은 dedup key는 항상 같은 partition과 worker에서 순차 처리 |

`received_at`과 `message_id`가 모두 같지만 다른 payload가 들어오는 경우는 정상적인 순서 비교로 해결할 수 없습니다. 이 경우를 데이터 계약 위반으로 기록하고 격리해야 합니다.

## 권장 처리 흐름

```text
durable event log
        ↓ dedup key로 partition
stateful correction processor
        ├─ current representative state
        ├─ input offset / checkpoint
        └─ deterministic correction record
                    ↓
          idempotent correction sink
                    ↓
        ClickHouse summary delta (+1 / -1)
```

stateful processor는 Kafka Streams, Flink 같은 스트림 처리기나 동일한 보장을 제공하는 애플리케이션으로 구현할 수 있습니다. 제품 선택보다 다음 계약을 먼저 충족해야 합니다.

1. 같은 dedup key의 이벤트를 한 worker에서 순서대로 처리합니다.
2. 현재 대표 상태와 입력 offset을 장애 후 함께 복구합니다.
3. 상태 변경과 correction 출력 사이에 장애가 발생해도 출력이 누락되거나 두 번 적용되지 않습니다.
4. ClickHouse 쓰기 재시도는 correction 단위의 영속적인 멱등성을 보장합니다.

`ReplicatedMergeTree`의 block deduplication이나 `SummingMergeTree` background merge만으로 4번을 충족한 것으로 판단하지 않습니다. block deduplication window 밖의 재시도와 서로 다른 block으로 재구성된 입력도 검증해야 합니다.

## 대표 상태

dedup key마다 아래 값을 보존합니다.

| 필드 | 용도 |
|---|---|
| `message_id` | 동률 결정과 대표 식별 |
| `mall_id`, `store_id`, `product_id` | 이벤트 summary bucket |
| `customer_group_ids` | 고객 그룹 summary bucket |
| `event_kind` | summary 차원 |
| `occurred_at` | 시간 bucket 결정 |
| `received_at` | 대표 우선순위 |
| `source_offset` | 처리 위치와 감사 추적 |
| `state_version` | 상태 변경 순서와 낙관적 동시성 검사 |

state TTL을 적용하면 TTL보다 늦게 도착한 이벤트의 이전 대표를 알 수 없습니다. exact 결과를 유지하려면 state 보존 기간을 최대 지연 도착 기간 이상으로 두고, 그 기간을 넘는 데이터는 reconciliation 대상으로 보내야 합니다. 지연 허용 기간이 정해지지 않았다면 state를 임의로 삭제하지 않습니다.

## 상태 전이와 delta

| 현재 대표 | 새 이벤트 | 상태 변경 | summary delta |
|---|---|---|---|
| 없음 | 최초 이벤트 | 새 이벤트 저장 | 새 bucket `+1` |
| 있음 | 우선순위가 같거나 늦음 | 없음 | 없음 |
| 있음 | 더 이른 이벤트 | 새 이벤트로 교체 | 이전 bucket `-1`, 새 bucket `+1` |

대표가 바뀌어도 summary 차원이 모두 같으면 `-1/+1`은 상쇄됩니다. 이 경우 대표 상태와 감사 기록만 변경하고 ClickHouse delta는 생략할 수 있습니다.

고객 그룹 summary는 다음과 같이 보정합니다.

1. 이전 대표의 중복 제거된 그룹마다 이전 bucket `-1`
2. 새 대표의 중복 제거된 그룹마다 새 bucket `+1`
3. 이전·신규 bucket이 같은 항목은 net delta를 계산해 0이면 생략

## correction 멱등성

correction에는 재시작 후에도 같은 값을 만드는 결정적 ID가 필요합니다.

```text
correction_id = hash(
  dedup_key,
  old_representative의 (received_at, message_id) 또는 null,
  new_representative의 (received_at, message_id)
)
```

하나의 대표 변경에서 이벤트 summary와 여러 고객 그룹 delta가 만들어지므로 각 출력 행에는 `correction_id`, `summary_kind`, bucket 식별자를 함께 둡니다.

processor는 상태 저장과 correction log 출력을 하나의 transaction 또는 checkpoint에 묶어야 합니다. outbox를 사용해도 producer 측 누락만 막을 뿐 ClickHouse 반영과 ledger 기록 사이의 이중 쓰기 문제는 남습니다.

ClickHouse sink는 다음 방식 중 하나를 선택하고 장애 주입 테스트로 보장해야 합니다.

- 현재 `SummingMergeTree` delta 구조를 유지한다면 안정적인 batch와 `insert_deduplication_token`을 사용하고, block deduplication window가 최대 장애·재시도 기간보다 길어야 합니다. 영구 replay가 필요하면 window 밖 중복을 막을 별도 설계가 필요합니다.
- processor가 bucket의 절대 count와 단조 증가 version을 출력하고 `ReplacingMergeTree`에 저장한 뒤 조회에서 `argMax(count, version)` 또는 검증된 `FINAL` 경로를 사용합니다. 이 방식은 중복 delta 가산을 피하지만 조회·저장 schema와 성능을 다시 시험해야 합니다.
- 동일한 수준의 원자성과 영속적인 deduplication을 제공하는 sink를 사용합니다.

ledger 확인과 ClickHouse INSERT를 별도 단계로 실행하는 것만으로는 충분하지 않습니다. INSERT 성공 후 ledger 기록 전에 장애가 나면 같은 delta가 다시 적용될 수 있습니다.

ClickHouse에 적용 완료를 기록하기 전에 프로세스가 죽는 경우와, 적용 완료를 기록한 직후 offset commit 전에 죽는 경우를 모두 재현합니다.

## snapshot과 실시간 전환

snapshot backfill과 실시간 processor가 같은 구간을 동시에 반영하면 이중 집계가 생깁니다. 전환 절차를 다음과 같이 고정합니다.

1. durable event log에서 기준 offset `O`를 기록합니다.
2. `O`까지의 이벤트로 dedup state와 summary snapshot을 만듭니다.
3. 같은 snapshot으로 processor의 현재 대표 state를 초기화합니다.
4. processor를 `O + 1`부터 시작합니다.
5. shadow query로 snapshot 기준값과 실시간 summary를 비교합니다.
6. 차이가 0이고 반영 지연이 목표 안에 들면 서비스 조회를 전환합니다.

초기화 도중 입력을 멈출 수 없다면 offset 범위를 명시한 immutable snapshot을 사용해야 합니다. ClickHouse 테이블의 실행 시점만 기록한 backfill은 전환 경계로 사용하지 않습니다.

현재 22,100,000개 dedup state의 이벤트·고객 그룹 summary를 새 replicated target에 shard 병렬로 전체 생성하면 49초가 걸렸습니다. 따라서 periodic refresh를 임시안으로 사용할 경우 refresh 간격 `I`에 대한 실제 가시성 지연은 약 `49초~(I+49초)`입니다. 이 수치는 현재 lab 데이터와 자원의 측정값이며, 입력 증가율과 보존 기간에 따라 반복 측정해야 합니다.

## 실패 처리와 reconciliation

### 재시도와 격리

- 일시적 ClickHouse 오류는 지수 backoff와 jitter로 재시도합니다.
- 최대 재시도를 넘긴 correction은 원본 payload, dedup key, correction ID, 시도 횟수, 최초·최종 오류 시각과 함께 실패 큐에 보존합니다.
- 실패 큐로 이동한 correction의 input offset을 진행할지는 순서 보장 방식과 함께 결정합니다. 같은 key의 후속 처리가 앞선 실패를 추월하면 안 됩니다.
- 운영자가 실패 correction을 재처리해도 같은 correction ID를 사용합니다.

### 정합성 대조

실시간 경로와 별도로 immutable event 구간에서 dedup 결과를 다시 계산해 summary와 비교합니다.

| 검사 | 이상 조건 |
|---|---|
| 전체 event count | dedup 기준과 summary 합계 불일치 |
| 상품·시간·이벤트 | 어느 bucket이든 차이 발생 |
| 고객 그룹 | 중복 제거된 그룹 귀속 합계 불일치 |
| 음수 bucket | `sum(event_count) < 0` |
| correction ledger | 미적용 또는 중복 적용 ID 존재 |

차이를 고칠 때 summary 전체를 덮어쓰기보다 차이만 correction으로 만들고 동일한 멱등 경로를 통과시킵니다. 모든 수리 작업에는 원인, 대상 범위, correction ID와 전후 count를 남깁니다.

## 모니터링과 알림

| 지표 | 의미 |
|---|---|
| input consumer lag | processor가 원본 입력보다 뒤처진 정도 |
| event-to-summary latency p50/p95/p99/max | 이벤트 수신부터 조회 반영까지 지연 |
| representative change rate | 지연 도착으로 대표가 바뀌는 비율 |
| no-op retry rate | 중복·늦은 이벤트로 상태가 바뀌지 않은 비율 |
| correction emitted/applied/failed | 생성·적용·실패 correction 수 |
| correction retry count | sink 재시도와 장애 징후 |
| failed queue size/oldest age | 수동 개입이 필요한 적체 |
| reconciliation mismatch count | 기준 재계산과 summary 차이 |
| negative summary bucket count | 보정 순서 또는 중복 적용 오류 |
| checkpoint duration/failure | 상태 복구 가능성과 처리 정체 |
| ClickHouse replication queue/delay | summary replica 수렴 상태 |

알림 임계값은 운영 SLO를 정한 뒤 고정합니다. 특히 평균 지연만 보지 않고 p99, 최대 지연, 실패 큐의 가장 오래된 항목 시간을 함께 봅니다.

## 필수 테스트

| 시나리오 | 기대 결과 |
|---|---|
| 최초 이벤트 | 해당 bucket `+1` |
| 동일 message 재전송 | 변화 없음 |
| 같은 key의 늦은 이벤트 | 변화 없음 |
| 더 이른 이벤트, 같은 bucket | count 불변, 대표만 변경 |
| 더 이른 이벤트, 다른 시간 | 이전 시간 `-1`, 새 시간 `+1` |
| mall/store/group이 다른 새 대표 | 모든 이전 차원 제거 후 신규 차원 반영 |
| 같은 `received_at`, 다른 `message_id` | 작은 `message_id`가 대표 |
| 같은 correction 반복 전달 | 한 번 적용한 결과와 동일 |
| 상태 저장 직후 worker 종료 | 재시작 후 누락·중복 없음 |
| sink 적용 직후 offset commit 전 종료 | 재시작 후 중복 적용 없음 |
| ClickHouse 일시 중단 | 복구 후 backlog 해소와 최종 정합성 유지 |
| snapshot/live 전환 중 입력 지속 | 경계 구간 누락·이중 집계 없음 |
| 단일 replica·노드·Keeper 장애 | 복구 후 correction과 summary 수렴 |
| 22,200,000행 reconciliation | 모든 비교 차이 0 |

## 구현 작업 순서

### P0 · 정확성

1. durable event log와 dedup key partition 계약 확정
2. 대표 상태 schema와 state TTL 정책 확정
3. correction ID와 delta payload schema 확정
4. 상태·correction 출력의 원자성 방식 선택
5. ClickHouse sink 멱등성 구현
6. snapshot offset과 state bootstrap 구현
7. 재전송·대표 변경·worker crash 테스트 자동화

### P1 · 운영 복구

1. correction 실패 큐와 재처리 도구 구현
2. reconciliation query와 차이 correction 구현
3. lag·반영 지연·실패·불일치 metric과 alert 구현
4. ClickHouse 적재 중 replica·노드·Keeper 장애 시험
5. runbook에 중단·재시작·재처리·수리 절차 기록

### P2 · 용량과 성능

1. peak 입력과 대표 변경률에서 processor 처리량 측정
2. correction batch 크기별 ClickHouse 쓰기 비용 측정
3. state/checkpoint 저장량과 복구 시간 측정
4. summary part 수, merge backlog와 TTL 영향 측정
5. event-to-summary latency SLO 확정과 부하 시험

## 완료 기준

A5 실시간 보정은 다음 조건을 모두 만족할 때 완료로 판정합니다.

- 필수 테스트에서 누락, 이중 집계, 음수 bucket이 없습니다.
- processor와 ClickHouse를 반복 재시작한 뒤에도 결과가 snapshot exact 기준과 일치합니다.
- snapshot/live 전환 경계의 모든 offset이 한 번씩 반영됩니다.
- 실패 correction을 식별하고 동일 ID로 안전하게 재처리할 수 있습니다.
- reconciliation 차이가 0이고 replica queue와 delay가 정상 범위로 수렴합니다.
- 합의한 반영 지연과 복구 시간 SLO를 충족합니다.
