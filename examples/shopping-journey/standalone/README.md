# 단일 노드 기준 모델

기존 clickhouse-lab에 추가하는 독립 SQL 예제입니다. 기존 push-click-service나 Kubernetes 매니페스트를 교체하지 않습니다. 예제 데이터베이스는 `shop_analytics`, 선택적인 MySQL 통계 스키마는 `shop_reporting`입니다.

[전체 케이스 안내](../README.md) · [데이터 결과 기준](../expected/data-result.md)

## 무엇을 다루는가

쇼핑몰 → 매장 → 상품에 연결된 구매 여정에서 알림 발송, 링크 클릭, 상품 조회, 장바구니 담기, 구매 이벤트를 수집합니다. 알림 발송은 고객 행동이 아니므로 전체를 **구매 여정 이벤트**라고 부릅니다.

```text
정규화·속성 보강이 완료된 공통 테스트 데이터
                    ↓
             shopping_events
                    ├─ 누적 HLL 조회
                    ├─ recent_event_keys
                    └─ first_event_states
                               ↓
                         first_events
                               ↓
                배치 계산 → MySQL RDS 통계 조회
```

상위 입력을 포함한 전체 참고 구조와 RDS 배치는 [ERD](../docs/architecture.md)에 설명되어 있습니다.

## 파일

| 파일 | 내용 |
|---|---|
| [schema/clickhouse.sql](./schema/clickhouse.sql) | ClickHouse 테이블 3개, MV 2개, 일반 View 1개 |
| [schema/rds-mysql.sql](./schema/rds-mysql.sql) | 선택적 RDS 통계 테이블 예제 |
| [sample-data.sql](./sample-data.sql) | 정규화된 가상 구매 여정 이벤트 6행 |
| [queries.sql](./queries.sql) | 누적 HLL 조회, RDS 배치 계산용 시간별·고객 그룹별 정확 집계 |
| [DDL 가정과 범위](../docs/ddl-notes.md) | 타입·키·미구현 경로·정책 변경 설명 |

## 실습 순서

선택한 **실습용 ClickHouse 단일 서버**에서 DDL → 샘플 데이터 → 조회 SQL 순서로 실행합니다.

연결 명령은 사용하는 실습 서버의 주소·인증에 맞춥니다. 이 예제는 ON CLUSTER, Distributed, Replicated 엔진을 적용하지 않았으므로 현재 여러 노드의 모든 Pod에 각각 실행하지 않습니다.

RDS 파일은 MySQL용이며 ClickHouse에서 실행하지 않습니다. RDS 테이블은 생성만으로 채워지지 않으며 배치 로더는 아직 없습니다.

MySQL 8.0.16 이상을 대상으로 합니다. 배치 연결의 시간대는 UTC로 설정하고, 계산한 전체 카운트로 기존 값을 교체해야 합니다. 재시도마다 더하는 방식은 중복 집계를 일으킵니다.

### 현재 kind lab에서 실행

저장소 루트에서 실행합니다. standalone 예제이므로 `clickhouse-0` 한 노드에만 적용합니다.

1. 대상 Pod가 실행 중인지 확인합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse get pod clickhouse-0
   ```

2. 빈 환경에 ClickHouse DDL을 적용합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i clickhouse-0 -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/standalone/schema/clickhouse.sql
   ```

   `shop_analytics`가 이미 존재하면 이 단계는 다시 실행하지 않습니다. 이 DDL은 초기 생성용이며 마이그레이션이나 반복 적용용 스크립트가 아닙니다.

3. 생성된 객체를 확인합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -c clickhouse \
     -- clickhouse-client -q \
     "SELECT name, engine FROM system.tables WHERE database = 'shop_analytics' ORDER BY name FORMAT PrettyCompact"
   ```

4. 샘플 6행을 입력합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i clickhouse-0 -c clickhouse \
     -- clickhouse-client --multiquery \
     < examples/shopping-journey/standalone/sample-data.sql
   ```

5. HLL·시간별·고객 그룹별 조회를 실행합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec -i clickhouse-0 -c clickhouse \
     -- clickhouse-client --multiquery --format PrettyCompact \
     < examples/shopping-journey/standalone/queries.sql
   ```

6. 재전송을 검증하려면 4번을 한 번 더 실행한 뒤 행 수를 확인합니다.

   ```bash
   kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -c clickhouse \
     -- clickhouse-client -q "
       SELECT
         (SELECT count() FROM shop_analytics.shopping_events) AS raw_rows,
         (SELECT count() FROM shop_analytics.recent_event_keys) AS recent_rows,
         (SELECT count() FROM shop_analytics.first_events) AS representative_rows,
         (SELECT message_id FROM shop_analytics.first_events
          WHERE journey_id = 'journey-a' AND event_kind = 'CLICK') AS selected_click
       FORMAT PrettyCompact"
   ```

### 실행 결과

2026-09-21에 ClickHouse `26.8.3.105`가 실행 중인 `clickhouse-0`에서 확인했습니다.

| 단계 | 확인 결과 |
|---|---|
| DDL 적용 | MergeTree 2개, AggregatingMergeTree 1개, MV 2개, View 1개 생성 |
| 샘플 1회 입력 | 원본 6행, recent 6행, 대표 이벤트 5행 |
| 시간별 집계 | 09시 NOTIFY 1, 10시 CLICK·VIEW·CART·PURCHASE 각각 1 |
| 고객 그룹별 집계 | 그룹 1은 5종 각각 1, 그룹 2는 VIEW·CART·PURCHASE 각각 1 |
| 동일 샘플 재입력 | 원본 12행, recent 12행, 대표 이벤트 5행 |
| 대표 CLICK | `demo-02` 유지 |

재입력 결과는 원본의 물리적 중복을 막았다는 뜻이 아닙니다. 원본과 recent에는 12행이 남고, `first_events` 조회에서 집계 상태를 병합해 대표 이벤트 5건을 반환합니다.

이 결과를 단일 노드 기준값으로 사용합니다. 이후 A1~A6 클러스터 케이스도 같은 입력에 대해 [데이터 결과 기준](../expected/data-result.md)을 만족해야 합니다.

## 결과 해석

CLICK은 발생 시각 10시의 이벤트가 먼저 수집되고, 09:30 이벤트가 나중에 수집됩니다. 현재 예제는 **최초 수집 기준**을 유지하므로 대표 CLICK은 10시입니다. 최소 발생 시각 기준으로 전환하면 이 기대값도 달라집니다.

같은 샘플을 다시 입력하면 원본 행은 증가합니다. 동일한 키와 내용이 유지되므로 대표 이벤트의 고유 건수는 그대로여야 합니다. 물리적 INSERT 중복 차단 기능을 구현한 예제는 아닙니다.

샘플은 최초 5행과 늦게 수집된 CLICK 1행을 별도 INSERT로 입력합니다. 서로 다른 입력 블록 사이에서도 대표 CLICK이 유지되는지 확인하기 위한 구성입니다. 위 기대값은 `clickhouse-0` 단일 노드에서 실행해 확인했습니다.

고객 그룹 조회는 RDS 그룹 키에 맞춰 매장 내 **전체 상품·전체 기간**을 집계합니다. 상품별 조회 결과를 이 그룹 키에 저장하면 다른 상품의 카운트를 덮어쓸 수 있습니다. HLL 조회는 근사값이므로 정확 집계와 구분합니다.

## 현재 구현 범위

- 문서, 테이블 정의, 원본 → recent/최초 상태 MV, 일반 조회 View, 샘플과 조회 SQL을 제공합니다.
- 실험은 shopping_events에서 시작합니다. JSON 수집·파싱·규칙 평가·매핑 JOIN 테이블과 MV는 범위 밖이며 이 DDL에는 없습니다.
- 성능 측정 대상은 shopping_events 이후의 저장·집계·조회이며 전체 수집 파이프라인 성능이 아닙니다.
- 독립 API 앱, RDS 배치, 실시간 통계 갱신기, 성능 테스트 결과는 아직 없습니다.
- 최초 선택은 received_at 기준이고 동률은 message_id로 결정합니다. 최소 occurred_at 기준 개선안과 혼동하지 않습니다.
- ClickHouse DDL·샘플·조회 SQL은 `clickhouse-0` 단일 노드에서 실행 검증했습니다. 같은 샘플을 재입력했을 때 원본은 12행, 대표 이벤트는 5행으로 유지됐습니다.
- MySQL DDL과 RDS 배치 로더는 아직 실행 검증하지 않았습니다.
