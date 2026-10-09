# A5 · a5-dedup_summary-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | dedup → summary → count |
| 시간·고객 그룹별 | dedup → summary → count |
| 생성 흐름 | event → dedup → summary |
| 필요한 저장 대상 | event, dedup, 상품별·그룹별 summary |
| 계획된 독립 DB | shop_a5 |

## 구현할 범위

dedup에서 파생한 summary의 실시간 갱신·대표 변경 보정·재시도 정책과 count 조회를 구현합니다.

현재는 케이스 정의만 작성했습니다. 클러스터용 DDL, 배포 스크립트, 실행 결과는 없습니다.

summary는 실시간 갱신·보정 구현이 필요합니다. dedup 뒤에 단순 카운트 MV를 붙이는 것으로 완료되지 않습니다. 주기적 재계산을 실시간 요구를 충족한 것으로 간주하지 않습니다.
