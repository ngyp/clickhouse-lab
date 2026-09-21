# A3 · a3-event-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | event → 최초 선택 후 count |
| 시간·고객 그룹별 | event → 최초 선택 후 count |
| 생성 흐름 | event에서 조회 시 dedup·count |
| 필요한 저장 대상 | event |
| 계획된 독립 DB | shop_a3 |

## 구현할 범위

event 원본에서 `(journey_id, event_kind)`별 최초 이벤트를 조회 시점에 선별하고, 누적·시간·그룹별 count를 계산하는 SQL을 구현합니다. 원본 행을 단순 count하는 케이스가 아닙니다.

현재는 케이스 정의만 작성했습니다. 클러스터용 DDL, 배포 스크립트, 실행 결과는 없습니다.
