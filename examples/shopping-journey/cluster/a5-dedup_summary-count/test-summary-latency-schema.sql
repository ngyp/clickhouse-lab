-- incremental chained MV의 insert 지연과 즉시 가시성을 측정하는 단일 노드 테스트 DB다.

DROP DATABASE IF EXISTS shop_a5_latency_test;
CREATE DATABASE shop_a5_latency_test;

CREATE TABLE shop_a5_latency_test.raw_events
(
    message_id String,
    product_id UInt64,
    journey_id String,
    event_kind LowCardinality(String),
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (product_id, journey_id, event_kind, received_at, message_id);

CREATE TABLE shop_a5_latency_test.chain_events
AS shop_a5_latency_test.raw_events
ENGINE = MergeTree
ORDER BY (product_id, journey_id, event_kind, received_at, message_id);

CREATE TABLE shop_a5_latency_test.chain_states
(
    product_id UInt64,
    journey_id String,
    event_kind LowCardinality(String),
    first_event_state AggregateFunction(
        argMin,
        Tuple(DateTime64(3, 'UTC'), String),
        Tuple(DateTime64(3, 'UTC'), String)
    )
)
ENGINE = AggregatingMergeTree
ORDER BY (product_id, journey_id, event_kind);

CREATE MATERIALIZED VIEW shop_a5_latency_test.events_to_states
TO shop_a5_latency_test.chain_states
AS
SELECT
    product_id,
    journey_id,
    event_kind,
    argMinState(
        tuple(occurred_at, message_id),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_a5_latency_test.chain_events
GROUP BY product_id, journey_id, event_kind;

CREATE TABLE shop_a5_latency_test.naive_summary
(
    product_id UInt64,
    hour_start DateTime('UTC'),
    event_kind LowCardinality(String),
    event_count UInt64
)
ENGINE = SummingMergeTree
ORDER BY (product_id, hour_start, event_kind);

CREATE MATERIALIZED VIEW shop_a5_latency_test.states_to_summary
TO shop_a5_latency_test.naive_summary
AS
SELECT
    product_id,
    toStartOfHour(representative.1) AS hour_start,
    event_kind,
    count() AS event_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a5_latency_test.chain_states
    GROUP BY product_id, journey_id, event_kind
)
GROUP BY product_id, hour_start, event_kind;
