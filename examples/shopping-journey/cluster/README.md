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

## 구현 순서

1. A2·A3·A4: 정규화된 이벤트 입력부터 분산 저장·복제·상태 집계와 직접 조회를 비교.
2. A1: RDS 배치를 연결해 기존 방식과 비교.
3. A5·A6: summary의 실시간 갱신·보정 방식이 정해진 뒤 구현.

A2는 클러스터 DDL·샘플·대용량 생성기와 조회 SQL을 구현해 3 shard × 3 replica에서 실행 검증했습니다. A5와 A6는 4 shard × 3 replica에서 snapshot dedup·summary 정합성, 조회 성능과 단일 replica 장애를 검증했습니다. A6의 전체 HLL은 전체 event 종류 기준 3% 오차를 통과했지만 일반 상품 CLICK 구간에서 3.340%로 실패했습니다. A5·A6 모두 상세 summary의 실시간 재시도·대표 변경 보정이 구현되지 않아 운영 준비 미통과 상태입니다. A1·A3·A4는 현재 설계 범위만 준비한 상태입니다.

모든 케이스는 구현 후 [데이터 결과 기준](../expected/data-result.md)을 먼저 통과해야 하며, 그다음 [성능](../expected/performance.md)과 [가용성·복구](../expected/availability-recovery.md)를 비교합니다.

## 공통 원본은 한 번만 적재

조회 구조 비교에서는 [common](./common/README.md)의 `shop_benchmark.shopping_events`를 한 번만 생성합니다. A1~A6은 이 불변 원본을 직접 조회하거나, 케이스별 dedup·summary 테이블에 `INSERT SELECT`로 backfill합니다. 케이스마다 합성 원본을 다시 만들지 않으므로 입력 차이와 반복 적재 시간을 제거할 수 있습니다.

```text
shop_benchmark.shopping_events
  ├─ A1: event HLL / dedup backfill / RDS
  ├─ A2: event HLL / dedup backfill 후 직접 count
  ├─ A3: event에서 최초 선택 후 count
  ├─ A4: dedup backfill 후 직접 count
  ├─ A5: dedup·summary backfill 후 count
  └─ A6: event HLL / dedup·summary backfill 후 count
```

원본 조회 성능과 파생 테이블 조회 성능은 공통 snapshot으로 비교합니다. MV 반영 지연과 원본 적재 처리량은 쓰기 경로 자체가 비교 대상이므로 A1~A6을 각각 초기화한 뒤 별도의 동일 입력으로 측정합니다.
