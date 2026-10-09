# 쇼핑몰 추가 예제 DDL 안내

DDL은 [examples/shopping-journey](../README.md)에 모았습니다. 기존 앱을 교체하지 않는 독립 예제이며, `shop_analytics` 데이터베이스를 사용합니다.

[쇼핑몰 ERD](./architecture.md)를 SQL 자료형과 엔진으로 구체화한 예제입니다.
실제 운영 DB에서 추출한 DDL이나 기존 애플리케이션의 마이그레이션이 아닙니다.

| 파일 | 내용 |
|---|---|
| [clickhouse.sql](../standalone/schema/clickhouse.sql) | ClickHouse 테이블 3개, MV 2개, 일반 조회 View 1개 |
| [rds-mysql.sql](../standalone/schema/rds-mysql.sql) | MySQL 예제 통계 테이블 4개 |

## 범위와 가정

- ClickHouse는 단일 노드 문법을 사용합니다. 복제·샤딩·ON CLUSTER 구성은 포함하지 않습니다.
- RDS 예제는 MySQL 8.0.16 이상(8.4 포함) 문법으로 작성했습니다.
- 이벤트 차원 ID는 UInt64, 여정·메시지 ID는 String, 그룹 목록은 Array(UInt64)로 가정했습니다. MySQL 식별자는 BIGINT UNSIGNED이며 예제 차원 ID는 양수로 제한합니다.
- 시각은 DateTime64(3, 'UTC')입니다. 수집 시각을 재시도 시점의 now()로 덮어쓰지 않고 원래 값으로 전달하는 계약을 가정합니다.
- 대표 이벤트는 현재 구조대로 최소 received_at을 선택합니다. 동률 처리용 message_id를 예제에 추가했습니다.
- message_id는 재전송에서도 고정되며 동일 ID의 내용은 변하지 않아야 합니다. 서로 다른 이벤트에는 서로 다른 ID를 부여합니다.
- 구매 여정 이벤트는 매핑이 완료된 상태로 들어온다고 가정합니다. NULL 매핑, 실패 데이터 재처리 정책은 별도입니다.
- TTL은 정하지 않았습니다. 정렬 키와 월 파티션은 검토 가능한 예제 선택이며 원본 설정을 복원한 것이 아닙니다.

## 포함한 MV

```text
shopping_events
  ├─ recent_event_mv → recent_event_keys
  └─ first_event_mv  → first_event_states → first_events (일반 View)
```

## 실험의 시작점과 입력 계약

shopping_events에 정규화·속성 보강이 완료된 이벤트를 직접 입력합니다.
상품과 여정의 연결, 이벤트 종류, 고객 그룹 목록, 발생·수집 시각을 입력 측에서 확정합니다.
message_id는 재전송 시 유지하고, 동일 ID에 다른 내용을 사용하지 않습니다.

다음 상위 테이블과 관련 MV는 실행용 DDL에서 제외했습니다. 전체 ERD에는 참고 맥락으로만 남깁니다.

- shop_web_log, shop_web_raw
- shop_action_rules, journey_map
- notification_raw, shop_link_log

이 실험은 저장·중복 상태 집계·조회·클러스터 분산/복제를 비교하며,
JSON 파싱이나 JOIN의 비용·정확성은 포함하지 않습니다.
기존 DB에 상위 테이블이 이미 있더라도 이 파일 변경으로 자동 삭제되지 않습니다.
DROP이나 기존 데이터 마이그레이션은 수행하지 않습니다.

RDS 배치 및 미래의 ClickHouse 통계 테이블 갱신기는 포함하지 않았습니다. 키 테이블과 카운트 테이블 생성만으로 통계가 채워지지는 않습니다.

## 최소 발생 시각 정책으로 바꾸려면

현재 MV의 비교 값은 tuple(received_at, message_id)입니다.
개선안은 tuple(occurred_at, message_id)를 비교 값으로 사용합니다.

이를 기존 데이터가 있는 MV에서 식만 바꾸는 식으로 적용하면 서로 다른 정책의 상태가 섞입니다. 별도의 상태 테이블과 MV를 만들고 원본에서 일관된 기준으로 재구축해야 합니다. first_received_at의 역할도 함께 검토해야 합니다.

## 검증 상태

SQL 구성과 상태 타입·입력 Tuple의 순서를 정적으로 확인했습니다.
ClickHouse DDL·샘플·조회 SQL은 `clickhouse-0` 단일 노드에서 실행했습니다. 샘플 1회 입력 결과는 원본 6행·대표 이벤트 5행이었고, 동일 샘플 재입력 후에는 원본 12행·대표 이벤트 5행이었습니다.
MySQL DDL은 아직 서버에서 실행하지 않았으므로 문법·동작 검증이 필요합니다.

새 빈 예제 DB에서 모든 목적 테이블과 MV를 준비한 뒤 적재해야 합니다.
MV 생성 전 데이터는 자동 반영되지 않습니다.

## 문법 참고

- [ClickHouse SimpleAggregateFunction](https://clickhouse.com/docs/reference/data-types/simpleaggregatefunction)
- [ClickHouse argMin](https://clickhouse.com/docs/reference/functions/aggregate-functions/argMin)
- [MySQL CREATE TABLE](https://dev.mysql.com/doc/refman/8.4/en/create-table.html)
