-- A6: 전체 누적은 event HLL, 시간·고객 그룹 상세는 dedup 기반 exact summary로 조회한다.

CREATE DATABASE IF NOT EXISTS shop_a6 ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_a6.shopping_events_local ON CLUSTER 'cluster1'
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
    '/clickhouse/tables/{shard}/shop_a6/shopping_events_local',
    '{replica}'
)
PARTITION BY toYYYYMM(received_at)
ORDER BY (product_id, journey_id, event_kind, occurred_at, message_id);

CREATE TABLE IF NOT EXISTS shop_a6.shopping_events ON CLUSTER 'cluster1'
AS shop_a6.shopping_events_local
ENGINE = Distributed(
    'cluster1',
    'shop_a6',
    'shopping_events_local',
    cityHash64(journey_id)
);

CREATE TABLE IF NOT EXISTS shop_a6.first_event_states_local ON CLUSTER 'cluster1'
(
    product_id UInt64,
    journey_id String,
    event_kind LowCardinality(String),
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
    '/clickhouse/tables/{shard}/shop_a6/first_event_states_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, event_kind);

CREATE TABLE IF NOT EXISTS shop_a6.first_event_states ON CLUSTER 'cluster1'
AS shop_a6.first_event_states_local
ENGINE = Distributed(
    'cluster1',
    'shop_a6',
    'first_event_states_local',
    cityHash64(journey_id)
);

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a6.first_event_mv ON CLUSTER 'cluster1'
TO shop_a6.first_event_states_local
AS
SELECT
    product_id,
    journey_id,
    event_kind,
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
FROM shop_a6.shopping_events_local
GROUP BY product_id, journey_id, event_kind;

CREATE TABLE IF NOT EXISTS shop_a6.event_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    hour_start DateTime('UTC'),
    event_kind LowCardinality(String),
    event_count Int64
)
ENGINE = ReplicatedSummingMergeTree(
    '/clickhouse/tables/{shard}/shop_a6/event_summary_local',
    '{replica}'
)
PARTITION BY toYYYYMM(hour_start)
ORDER BY (mall_id, store_id, product_id, hour_start, event_kind);

CREATE TABLE IF NOT EXISTS shop_a6.event_summary ON CLUSTER 'cluster1'
AS shop_a6.event_summary_local
ENGINE = Distributed(
    'cluster1',
    'shop_a6',
    'event_summary_local',
    cityHash64(product_id)
);

CREATE TABLE IF NOT EXISTS shop_a6.customer_group_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    hour_start DateTime('UTC'),
    customer_group_id UInt64,
    event_kind LowCardinality(String),
    event_count Int64
)
ENGINE = ReplicatedSummingMergeTree(
    '/clickhouse/tables/{shard}/shop_a6/customer_group_summary_local',
    '{replica}'
)
PARTITION BY toYYYYMM(hour_start)
ORDER BY (
    mall_id,
    store_id,
    product_id,
    hour_start,
    customer_group_id,
    event_kind
);

CREATE TABLE IF NOT EXISTS shop_a6.customer_group_summary ON CLUSTER 'cluster1'
AS shop_a6.customer_group_summary_local
ENGINE = Distributed(
    'cluster1',
    'shop_a6',
    'customer_group_summary_local',
    cityHash64(customer_group_id)
);
