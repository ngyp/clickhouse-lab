DROP DATABASE IF EXISTS shop_a7_hybrid_100m;
CREATE DATABASE shop_a7_hybrid_100m;

-- 모든 방식이 공유하는 1억 행 기존 이력.
CREATE TABLE shop_a7_hybrid_100m.event_history
(
    ingest_row_id UInt64,
    product_id UInt64,
    tracking_id UInt64,
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (product_id, tracking_id, occurred_at, ingest_row_id);

-- 최초 입수 고정 방식: tracking ID마다 이미 대표 한 행이 있다.
CREATE TABLE shop_a7_hybrid_100m.direct_first
(
    product_id UInt64,
    tracking_id UInt64,
    occurred_at DateTime64(3, 'UTC'),
    first_received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (product_id, tracking_id);

CREATE TABLE shop_a7_hybrid_100m.direct_input
AS shop_a7_hybrid_100m.event_history
ENGINE = MergeTree
ORDER BY (product_id, tracking_id, received_at, ingest_row_id);

CREATE MATERIALIZED VIEW shop_a7_hybrid_100m.direct_input_mv
TO shop_a7_hybrid_100m.direct_first AS
WITH candidates AS
(
    SELECT
        product_id,
        tracking_id,
        argMin(tuple(occurred_at, received_at), tuple(received_at, ingest_row_id)) AS candidate
    FROM shop_a7_hybrid_100m.direct_input
    GROUP BY product_id, tracking_id
),
existing_keys AS
(
    SELECT product_id, tracking_id
    FROM shop_a7_hybrid_100m.direct_first
    WHERE (product_id, tracking_id) IN
    (
        SELECT product_id, tracking_id FROM candidates
    )
)
SELECT
    c.product_id,
    c.tracking_id,
    candidate.1 AS occurred_at,
    candidate.2 AS first_received_at
FROM candidates AS c
LEFT ANTI JOIN existing_keys AS e
    ON e.product_id = c.product_id
   AND e.tracking_id = c.tracking_id;

-- Replacing 방식: 후보 1억 행을 유지하고 version이 가장 빠른 시각을 선택한다.
CREATE TABLE shop_a7_hybrid_100m.replacing_first
(
    product_id UInt64,
    tracking_id UInt64,
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC'),
    first_version UInt64 MATERIALIZED bitNot(toUInt64(toUnixTimestamp64Milli(occurred_at)))
)
ENGINE = ReplacingMergeTree(first_version)
ORDER BY (product_id, tracking_id);

CREATE TABLE shop_a7_hybrid_100m.replacing_input
AS shop_a7_hybrid_100m.event_history
ENGINE = MergeTree
ORDER BY (product_id, tracking_id, received_at, ingest_row_id);

CREATE MATERIALIZED VIEW shop_a7_hybrid_100m.replacing_input_mv
TO shop_a7_hybrid_100m.replacing_first AS
SELECT product_id, tracking_id, occurred_at, received_at
FROM shop_a7_hybrid_100m.replacing_input;

-- Delta 방식: 현재 대표 시간의 +1과 시간 이동의 -1/+1을 보관한다.
CREATE TABLE shop_a7_hybrid_100m.delta_log
(
    product_id UInt64,
    event_hour DateTime('UTC'),
    count_delta Int64
)
ENGINE = MergeTree
ORDER BY (product_id, event_hour);

CREATE TABLE shop_a7_hybrid_100m.delta_input
AS shop_a7_hybrid_100m.event_history
ENGINE = MergeTree
ORDER BY (product_id, tracking_id, occurred_at, ingest_row_id);

CREATE MATERIALIZED VIEW shop_a7_hybrid_100m.delta_input_mv
TO shop_a7_hybrid_100m.delta_log AS
WITH candidates AS
(
    SELECT
        product_id,
        tracking_id,
        min(occurred_at) AS candidate_at
    FROM shop_a7_hybrid_100m.delta_input
    GROUP BY product_id, tracking_id
),
history_for_candidates AS
(
    SELECT product_id, tracking_id, occurred_at
    FROM shop_a7_hybrid_100m.event_history
    WHERE (product_id, tracking_id) IN
    (
        SELECT product_id, tracking_id FROM candidates
    )
),
evaluated AS
(
    SELECT
        c.product_id,
        c.tracking_id,
        c.candidate_at,
        count(h.tracking_id) AS history_count,
        min(h.occurred_at) AS previous_at
    FROM candidates AS c
    LEFT JOIN history_for_candidates AS h
        ON h.product_id = c.product_id
       AND h.tracking_id = c.tracking_id
    GROUP BY c.product_id, c.tracking_id, c.candidate_at
)
SELECT
    product_id,
    delta.1 AS event_hour,
    delta.2 AS count_delta
FROM evaluated
ARRAY JOIN
    multiIf(
        history_count = 0,
        [tuple(toDateTime(toStartOfHour(candidate_at), 'UTC'), toInt64(1))],
        candidate_at < previous_at,
        [
            tuple(toDateTime(toStartOfHour(previous_at), 'UTC'), toInt64(-1)),
            tuple(toDateTime(toStartOfHour(candidate_at), 'UTC'), toInt64(1))
        ],
        CAST([], 'Array(Tuple(DateTime(\'UTC\'), Int64))')
    ) AS delta;
