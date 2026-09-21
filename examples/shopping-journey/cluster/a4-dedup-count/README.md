# A4 · a4-dedup-count

[전체 비교](../README.md) · [공통 기준](../common/README.md) · [기대 기준](../../expected/README.md)

| 구분 | 경로 |
|---|---|
| 전체 누적 | dedup → 직접 count |
| 시간·고객 그룹별 | dedup → 직접 count |
| 생성 흐름 | event → dedup |
| 필요한 저장 대상 | event, dedup |
| 계획된 독립 DB | shop_a4 |

## 구현할 범위

클러스터용 테이블·로컬 MV와 dedup 상태 병합 후 누적·시간·그룹별 count 조회를 구현합니다.

현재는 케이스 정의만 작성했습니다. 클러스터용 DDL, 배포 스크립트, 실행 결과는 없습니다.
