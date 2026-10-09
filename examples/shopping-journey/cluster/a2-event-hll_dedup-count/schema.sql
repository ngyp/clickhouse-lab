-- A2: event HLL + dedup 직접 count
-- cluster1의 모든 replica에 로컬 테이블을 만들고 Distributed 테이블로 조회한다.

CREATE DATABASE IF NOT EXISTS shop_a2 ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_a2.shopping_events_local ON CLUSTER 'cluster1'
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
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a2/shopping_events_local',
    '{replica}'
)
PARTITION BY toYYYYMM(received_at)
ORDER BY (product_id, journey_id, event_kind, occurred_at, message_id);

CREATE TABLE IF NOT EXISTS shop_a2.shopping_events ON CLUSTER 'cluster1'
AS shop_a2.shopping_events_local
ENGINE = Distributed(
    'cluster1',
    'shop_a2',
    'shopping_events_local',
    cityHash64(journey_id)
);

CREATE TABLE IF NOT EXISTS shop_a2.first_event_states_local ON CLUSTER 'cluster1'
(
    product_id UInt64,
    journey_id String,
    event_kind LowCardinality(String),
    first_received_at SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    first_event_state AggregateFunction(
        argMin,
        Tuple(
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
ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/shop_a2/first_event_states_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, event_kind);

CREATE TABLE IF NOT EXISTS shop_a2.first_event_states ON CLUSTER 'cluster1'
AS shop_a2.first_event_states_local
ENGINE = Distributed(
    'cluster1',
    'shop_a2',
    'first_event_states_local',
    cityHash64(journey_id)
);

-- Distributed 입력은 한 shard의 한 replica에 전달되고 이 로컬 MV가 실행된다.
-- 결과 테이블의 Replicated 엔진이 같은 shard의 다른 replica로 상태를 복제한다.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a2.first_event_mv ON CLUSTER 'cluster1'
TO shop_a2.first_event_states_local
AS
SELECT
    product_id,
    journey_id,
    event_kind,
    min(received_at) AS first_received_at,
    argMinState(
        tuple(
            mall_id,
            store_id,
            customer_group_ids,
            occurred_at,
            received_at,
            toString(source_kind),
            message_id
        ),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_a2.shopping_events_local
GROUP BY product_id, journey_id, event_kind;

-- 모든 shard의 aggregate state를 조회 시 최종 병합한다.
CREATE VIEW IF NOT EXISTS shop_a2.first_events ON CLUSTER 'cluster1' AS
SELECT
    journey_id,
    event_kind,
    product_id,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    representative.3 AS customer_group_ids,
    representative.4 AS occurred_at,
    representative.5 AS received_at,
    representative.6 AS source_kind,
    representative.7 AS message_id
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a2.first_event_states
    GROUP BY product_id, journey_id, event_kind
);

-- 서비스의 상품 단위 조회용 parameterized View다.
-- product_id 조건을 Distributed 상태 테이블 안쪽에 강제해 전체 state 병합을 막는다.
CREATE VIEW IF NOT EXISTS shop_a2.first_events_by_product ON CLUSTER 'cluster1' AS
SELECT
    journey_id,
    event_kind,
    product_id,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    representative.3 AS customer_group_ids,
    representative.4 AS occurred_at,
    representative.5 AS received_at,
    representative.6 AS source_kind,
    representative.7 AS message_id
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a2.first_event_states
    WHERE product_id = {product_id:UInt64}
    GROUP BY product_id, journey_id, event_kind
);
