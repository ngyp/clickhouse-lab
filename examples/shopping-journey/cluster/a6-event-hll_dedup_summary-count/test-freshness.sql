DROP DATABASE IF EXISTS shop_a6_freshness_test;
CREATE DATABASE shop_a6_freshness_test;

CREATE TABLE shop_a6_freshness_test.shopping_events
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
ORDER BY (product_id, journey_id, event_kind, occurred_at, message_id);

CREATE TABLE shop_a6_freshness_test.first_event_states
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
ENGINE = AggregatingMergeTree
ORDER BY (product_id, journey_id, event_kind);

CREATE MATERIALIZED VIEW shop_a6_freshness_test.first_event_mv
TO shop_a6_freshness_test.first_event_states
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
FROM shop_a6_freshness_test.shopping_events
GROUP BY product_id, journey_id, event_kind;

CREATE TABLE shop_a6_freshness_test.event_summary
(
    product_id UInt64,
    event_count Int64
)
ENGINE = SummingMergeTree
ORDER BY product_id;

INSERT INTO shop_a6_freshness_test.shopping_events VALUES
(
    'a6-freshness-initial', 1, 1, 9000000001, 'a6-freshness-journey',
    [10, 20], 'CLICK', 'TEST',
    toDateTime64('2026-09-21 10:00:00', 3, 'UTC'),
    toDateTime64('2026-09-21 10:00:01', 3, 'UTC')
);

-- INSERT ACK 직후 첫 조회에서 event HLL과 dedup state가 보인다.
SELECT
    uniqExact(journey_id) AS exact_count,
    uniqHLL12(journey_id) AS hll_count,
    exact_count = 1 AND hll_count = 1 AS visible_after_insert_ack
FROM shop_a6_freshness_test.shopping_events
WHERE product_id = 9000000001 AND event_kind = 'CLICK';

SELECT
    argMinMerge(first_event_state).4 AS representative_time,
    representative_time = toDateTime64('2026-09-21 10:00:00', 3, 'UTC') AS passed
FROM shop_a6_freshness_test.first_event_states
WHERE product_id = 9000000001 AND event_kind = 'CLICK'
GROUP BY product_id, journey_id, event_kind;

-- summary는 자동 갱신 경로가 없으므로 아직 0이다.
SELECT
    coalesce(sum(event_count), 0) AS summary_count,
    summary_count = 0 AS summary_not_automatically_refreshed
FROM shop_a6_freshness_test.event_summary
WHERE product_id = 9000000001;

-- 재전송과 더 이른 대표 이벤트를 넣어도 HLL은 journey 하나로 유지된다.
INSERT INTO shop_a6_freshness_test.shopping_events VALUES
(
    'a6-freshness-retry', 1, 1, 9000000001, 'a6-freshness-journey',
    [10, 20], 'CLICK', 'TEST',
    toDateTime64('2026-09-21 10:00:00', 3, 'UTC'),
    toDateTime64('2026-09-21 10:05:00', 3, 'UTC')
),
(
    'a6-freshness-earlier', 1, 1, 9000000001, 'a6-freshness-journey',
    [30, 40], 'CLICK', 'TEST',
    toDateTime64('2026-09-21 09:00:00', 3, 'UTC'),
    toDateTime64('2026-09-21 09:00:01', 3, 'UTC')
);

SELECT
    count() AS raw_rows,
    uniqExact(journey_id) AS exact_count,
    uniqHLL12(journey_id) AS hll_count,
    raw_rows = 3 AND exact_count = 1 AND hll_count = 1 AS passed
FROM shop_a6_freshness_test.shopping_events
WHERE product_id = 9000000001 AND event_kind = 'CLICK';

SELECT
    argMinMerge(first_event_state).4 AS representative_time,
    representative_time = toDateTime64('2026-09-21 09:00:00', 3, 'UTC') AS passed
FROM shop_a6_freshness_test.first_event_states
WHERE product_id = 9000000001 AND event_kind = 'CLICK'
GROUP BY product_id, journey_id, event_kind;

DROP DATABASE shop_a6_freshness_test;
