# 클러스터 조회 구조 비교

[전체 안내](../README.md) · [공통 실험 기준](./common/README.md) · [기대 기준](../expected/README.md)

폴더 이름은 **누적 조회 경로_상세 조회 경로**를 표현합니다. 두 조회가 같은 경로이면 하나만 적습니다.

| 디렉터리 | 전체 누적 | 시간·그룹별 |
|---|---|---|
| [a1-event-hll_dedup_rds](./a1-event-hll_dedup_rds/README.md) | event → HLL | dedup → 배치 → RDS 통계 조회 |
| [a2-event-hll_dedup-count](./a2-event-hll_dedup-count/README.md) | event → HLL | dedup → 직접 count |
| [a3-event-count](./a3-event-count/README.md) | event → 최초 선택 후 count | event → 최초 선택 후 count |
| [a4-dedup-count](./a4-dedup-count/README.md) | dedup → 직접 count | dedup → 직접 count |
| [a5-dedup_summary-count](./a5-dedup_summary-count/README.md) | dedup → summary → count | dedup → summary → count |
| [a6-event-hll_dedup_summary-count](./a6-event-hll_dedup_summary-count/README.md) | event → HLL | dedup → summary → count |
| [a7-event-replacing_summary-count](./a7-event-replacing_summary-count/README.md) | A7-1 이벤트별 Replacing → `count_delta` 숫자 Summary | A7-2 최초 상태 → signed delta 시간 Summary → 상품 단위 보정 |

## 구현 순서

1. A2·A3·A4: 정규화된 이벤트 입력부터 분산 저장·복제·상태 집계와 직접 조회를 비교.
2. A1: RDS 배치를 연결해 기존 방식과 비교.
3. A5·A6: dedup 기반 summary의 실시간 갱신·보정 방식이 정해진 뒤 구현.
4. A7: A7-1 누적 Summary를 구현하고, A7-2에서 직접 `FINAL`과 최초 상태 기반 시간 Summary를 비교한 뒤 정합성 보정을 추가.

A2는 event HLL과 dedup state 직접 조회, A3는 event 원본의 shard-local exact count, A4는 dedup state 기반 전체 exact count를 구현했습니다. A7-1은 이벤트별 ReplacingMergeTree와 `count_delta` 기반 누적 숫자 Summary, A7-2는 `first_event_state`와 signed delta 시간 Summary 및 상품 단위 보정을 구현했습니다. 아래 성능값은 `GUIDE(free operator).md`의 별도 3 shard × 3 replica 구성에서 실행해 얻었습니다. 저장소의 기본 `manifests/chi.yaml`은 Altinity Operator 기반 4 shard × 3 replica 구성이므로 동일한 측정 환경이 아닙니다. A1·A5·A6은 현재 설계 범위만 준비한 상태입니다.

| 구분 | 토폴로지 | 대표 Pod 이름 | 용도 |
|---|---|---|---|
| 저장소 기본 배포 | 4 shard × 3 replica | `chi-chi-cluster1-{0,1,2,3}-0-0` | `manifests/chi.yaml` 기반 재현 |
| 기존 성능 측정 배포 | 3 shard × 3 replica | `clickhouse-0`, `clickhouse-3`, `clickhouse-6` | free operator 가이드 기반 측정 |

DDL은 `{shard}`, `{replica}` 매크로와 `cityHash64(journey_id)` 샤딩을 사용하므로 두 토폴로지에 모두 적용할 수 있습니다. 실행 결과를 비교할 때는 shard 수, ClickHouse 버전과 Pod 자원을 함께 기록합니다.

모든 케이스는 구현 후 [데이터 결과 기준](../expected/data-result.md)을 먼저 통과해야 하며, 그다음 [성능](../expected/performance.md)과 [가용성·복구](../expected/availability-recovery.md)를 비교합니다.

## 공통 원본은 한 번만 적재

조회 구조 비교에서는 [common](./common/README.md)의 `shop_benchmark.shopping_events`를 한 번만 생성합니다. A1~A7은 이 불변 원본을 직접 조회하거나, 케이스별 dedup·summary 테이블에 `INSERT SELECT`로 backfill합니다. 케이스마다 합성 원본을 다시 만들지 않으므로 입력 차이와 반복 적재 시간을 제거할 수 있습니다.

```text
shop_benchmark.shopping_events
  ├─ A1: event HLL / dedup backfill / RDS
  ├─ A2: event HLL / dedup backfill 후 직접 count
  ├─ A3: event에서 최초 선택 후 count
  ├─ A4: dedup backfill 후 직접 count
  ├─ A5: dedup·summary backfill 후 count
  ├─ A6: event HLL / dedup·summary backfill 후 count
  └─ A7
      ├─ A7-1: 이벤트별 Replacing / count_delta 누적 Summary
      └─ A7-2: first state / signed delta 시간 Summary / 상품 단위 보정
```

원본 조회 성능과 파생 테이블 조회 성능은 공통 snapshot으로 비교합니다. MV 반영 지연과 원본 적재 처리량은 쓰기 경로 자체가 비교 대상이므로 A1~A7을 각각 초기화한 뒤 별도의 동일 입력으로 측정합니다. A7은 최초 이벤트 정책이 달라 결과 정확성은 전용 기대값으로 판정합니다.
