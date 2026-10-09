-- clickhouse-lab 추가 예제: 쇼핑몰 구매 여정 분석 / 단일 노드 ClickHouse용 DDL 초안
-- 실제 시스템에서 추출한 DDL이 아니다. clickhouse-0 단일 노드에서 실행 검증했다.
-- 새 빈 데이터베이스에 적용하는 초기 정의이며, 기존 스키마 마이그레이션이 아니다.
-- ON CLUSTER / Distributed / 복제 / TTL은 별도 결정한다.
-- 실험 시작점은 정규화된 shopping_events이다.
-- JSON 수집·파싱·규칙 평가·매핑 JOIN의 테이블과 MV는 실험 범위 밖이다.
-- shopping_events에 정규화된 데이터를 입력하면 recent/first MV가 작동하는 구성이다.

CREATE DATABASE IF NOT EXISTS shop_analytics;

-- 1. 구매 여정 이벤트 원본
-- 예제의 보강 완료 이벤트는 mall/store/product가 NOT NULL이라고 가정한다.
-- 매핑 실패 이벤트를 임의의 0 ID로 채우는 동작은 이 DDL에 없다.
-- message_id는 재시도 시에도 동일하게 유지되는 이벤트 식별자이며,
-- 동일 ID는 동일한 이벤트 내용이라는 입력 계약을 사용한다.
CREATE TABLE shop_analytics.shopping_events
(
    message_id String,
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    journey_id String,
    customer_group_ids Array(UInt64),
    event_kind LowCardinality(String),
    source_kind LowCardinality(String),
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(received_at)
ORDER BY (product_id, journey_id, event_kind, occurred_at, message_id);

-- 2. 배치 대상 탐색용 최근 키: 중복이 들어올 수 있다.
-- 보존/워터마크/장애 복구 정책 미정으로 TTL을 두지 않는다.
CREATE TABLE shop_analytics.recent_event_keys
(
    journey_id String,
    event_kind LowCardinality(String),
    received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(received_at)
ORDER BY (received_at, journey_id, event_kind);

-- 3. 현재 구조: 최초 수집 시각 기준 집계 상태
-- 시간 파티션을 두지 않아 같은 키의 상태를 날짜별로 분리하지 않는다.
-- 논리 키는 (journey_id, event_kind); 물리적 중복 삽입을 차단하지 않는다.
--
-- first_event_state의 반환 Tuple 순서:
-- 1 mall_id / 2 store_id / 3 product_id / 4 customer_group_ids
-- 5 occurred_at / 6 received_at / 7 source_kind / 8 message_id
--
-- 비교 값은 (received_at, message_id).
-- 최소 수집 시각을 우선하고 동률이면 message_id 사전순으로 고정한다.
-- 동일 message_id가 서로 다른 내용으로 재사용되면 이 가정이 깨진다.
CREATE TABLE shop_analytics.first_event_states
(
    journey_id String,
    event_kind LowCardinality(String),
    first_received_at SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    first_event_state AggregateFunction(
        argMin,
        Tuple(
            UInt64,
            UInt64,
            UInt64,
            Array(UInt64),
            DateTime64(3, 'UTC'),
            DateTime64(3, 'UTC'),
            String,
            String
        ),
        Tuple(DateTime64(3, 'UTC'), String)
    )
)
ENGINE = AggregatingMergeTree
ORDER BY (journey_id, event_kind);

-- 하위 목적 테이블이 준비된 후 MV를 생성한다.
-- 생성 전 이미 적재된 데이터는 자동 소급 처리하지 않는다.
CREATE MATERIALIZED VIEW shop_analytics.recent_event_mv
TO shop_analytics.recent_event_keys
AS
SELECT journey_id, event_kind, received_at
FROM shop_analytics.shopping_events;

CREATE MATERIALIZED VIEW shop_analytics.first_event_mv
TO shop_analytics.first_event_states
AS
SELECT
    journey_id,
    event_kind,
    min(received_at) AS first_received_at,
    argMinState(
        tuple(
            mall_id,
            store_id,
            product_id,
            customer_group_ids,
            occurred_at,
            received_at,
            toString(source_kind),
            message_id
        ),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_analytics.shopping_events
GROUP BY journey_id, event_kind;

-- 조회 편의용 일반 View. 결과를 저장하거나 주기적으로 갱신하는 MV가 아니다.
-- 상품/기간/그룹 조건은 반환된 대표 이벤트에 적용한다.
CREATE VIEW shop_analytics.first_events AS
SELECT
    journey_id,
    event_kind,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    representative.3 AS product_id,
    representative.4 AS customer_group_ids,
    representative.5 AS occurred_at,
    representative.6 AS received_at,
    representative.7 AS source_kind,
    representative.8 AS message_id
FROM
(
    SELECT
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_analytics.first_event_states
    GROUP BY journey_id, event_kind
);
