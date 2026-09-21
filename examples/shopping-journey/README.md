# 쇼핑몰 구매 여정 이벤트 예제

기존 clickhouse-lab의 추가 예제입니다. **단일 노드 기준 모델**과 **클러스터 조회 구조별 비교 케이스**를 분리합니다. 기존 앱과 매니페스트는 유지합니다.

## 구성

```text
shopping-journey/
├─ standalone/                       # 기존 DDL·샘플·쿼리 보존
│  ├─ README.md
│  ├─ schema/
│  │  ├─ clickhouse.sql
│  │  └─ rds-mysql.sql
│  ├─ sample-data.sql
│  └─ queries.sql
├─ cluster/
│  ├─ README.md
│  ├─ common/
│  ├─ a1-event-hll_dedup_rds/
│  ├─ a2-event-hll_dedup-count/
│  ├─ a3-event-count/
│  ├─ a4-dedup-count/
│  ├─ a5-dedup_summary-count/
│  └─ a6-event-hll_dedup_summary-count/
├─ expected/
│  ├─ README.md
│  ├─ data-result.md
│  ├─ performance.md
│  └─ availability-recovery.md
└─ docs/
   ├─ architecture.md
   └─ ddl-notes.md
```

## 실험 범위

모든 케이스의 입력은 정규화된 shopping_events입니다. JSON 수집·파싱·규칙 평가·매핑 JOIN은 제외합니다. 각 케이스는 필요한 하위 상태·통계 테이블만 추가합니다. 전체 ERD의 상위 입력 경로는 참고용입니다.

## 조회 대상과 방식

- **event**: 정규화된 구매 여정 이벤트인 shopping_events. JSON 원시 로그가 아닙니다.
- **dedup**: 최초 이벤트 집계 상태인 first_event_states. 조회 시 상태를 합칩니다.
- **summary**: dedup에서 파생한 사전 집계 테이블.
- **상세**: 최초 이벤트 기준의 시간별·고객 그룹별 통계.

| 케이스 | 전체 누적 조회 | 상세 조회 |
|---|---|---|
| [A1](./cluster/a1-event-hll_dedup_rds/README.md) | event → HLL | dedup → 배치 → RDS 통계 조회 |
| [A2](./cluster/a2-event-hll_dedup-count/README.md) | event → HLL | dedup → 직접 count |
| [A3](./cluster/a3-event-count/README.md) | event → 최초 선택 후 count | event → 최초 선택 후 count |
| [A4](./cluster/a4-dedup-count/README.md) | dedup → 직접 count | dedup → 직접 count |
| [A5](./cluster/a5-dedup_summary-count/README.md) | dedup → summary → count | dedup → summary → count |
| [A6](./cluster/a6-event-hll_dedup_summary-count/README.md) | event → HLL | dedup → summary → count |

RDS는 클러스터 비교 케이스 중 A1에만 사용합니다. A1은 standalone과 같은 조회·저장 경로를 클러스터에 적용하는 기준 케이스입니다.

## 현재 상태

- [standalone](./standalone/README.md): shopping_events부터 시작하는 테이블 3개·MV 2개·View 1개와 샘플을 제공합니다. `clickhouse-0` 단일 노드에서 실행 검증했습니다.
- [cluster](./cluster/README.md): 케이스별 구현·검증 범위를 정리했습니다. A2는 클러스터 DDL과 고정·대용량 데이터 검증을 완료했고, 나머지는 설계 단계입니다.
- [ERD](./docs/architecture.md): 기존 구조를 쇼핑몰 도메인으로 설명합니다. 모든 클러스터 케이스에 RDS가 필요하다는 의미는 아닙니다.
- [DDL 가정](./docs/ddl-notes.md): 현재 단일 노드 SQL의 타입·키·미구현 부분을 설명합니다.
- [기대 기준](./expected/README.md): 데이터 결과, 성능, 가용성·복구를 분리해 단일 노드와 A1~A6을 평가합니다.

다음 구현은 A2·A3·A4의 클러스터 DDL과 비교 쿼리부터 진행합니다. A1 배치와 A5·A6 실시간 summary 갱신은 별도 구현 대상입니다.
