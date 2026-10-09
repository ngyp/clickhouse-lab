DROP DATABASE IF EXISTS shop_a7_hybrid_bench;
CREATE DATABASE shop_a7_hybrid_bench;

-- 1. 최초 입수 한 건만 별도 MergeTree에 저장 -------------------------------
CREATE TABLE shop_a7_hybrid_bench.direct_raw
(
    ingest_row_id UInt64,
    product_id UInt64,
    journey_id String,
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (product_id, journey_id, received_at, ingest_row_id);

CREATE TABLE shop_a7_hybrid_bench.direct_first
(
    product_id UInt64,
    journey_id String,
    occurred_at DateTime64(3, 'UTC'),
    first_received_at DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (product_id, journey_id);

CREATE MATERIALIZED VIEW shop_a7_hybrid_bench.direct_first_mv
TO shop_a7_hybrid_bench.direct_first AS
WITH candidates AS
(
    SELECT
        product_id,
        journey_id,
        argMin(tuple(occurred_at, received_at), tuple(received_at, ingest_row_id)) AS candidate
    FROM shop_a7_hybrid_bench.direct_raw
    GROUP BY product_id, journey_id
),
existing_keys AS
(
    SELECT product_id, journey_id
    FROM shop_a7_hybrid_bench.direct_first
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id FROM candidates
    )
)
SELECT
    c.product_id,
    c.journey_id,
    candidate.1 AS occurred_at,
    candidate.2 AS first_received_at
FROM candidates AS c
LEFT ANTI JOIN existing_keys AS e
    ON e.product_id = c.product_id
   AND e.journey_id = c.journey_id;

-- 2. 모든 후보를 ReplacingMergeTree에 저장하고 FINAL로 최초 시각 선택 ------
CREATE TABLE shop_a7_hybrid_bench.replacing_raw
AS shop_a7_hybrid_bench.direct_raw
ENGINE = MergeTree
ORDER BY (product_id, journey_id, received_at, ingest_row_id);

CREATE TABLE shop_a7_hybrid_bench.replacing_first
(
    product_id UInt64,
    journey_id String,
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC'),
    first_version UInt64 MATERIALIZED bitNot(toUInt64(toUnixTimestamp64Milli(occurred_at)))
)
ENGINE = ReplacingMergeTree(first_version)
ORDER BY (product_id, journey_id);

CREATE MATERIALIZED VIEW shop_a7_hybrid_bench.replacing_first_mv
TO shop_a7_hybrid_bench.replacing_first AS
SELECT product_id, journey_id, occurred_at, received_at
FROM shop_a7_hybrid_bench.replacing_raw;

-- 3. 가장 빠른 발생 시각이 바뀔 때 signed delta 저장 ------------------------
CREATE TABLE shop_a7_hybrid_bench.delta_raw
AS shop_a7_hybrid_bench.direct_raw
ENGINE = MergeTree
ORDER BY (product_id, journey_id, occurred_at, ingest_row_id);

CREATE VIEW shop_a7_hybrid_bench.delta_raw_history AS
SELECT * FROM shop_a7_hybrid_bench.delta_raw;

CREATE TABLE shop_a7_hybrid_bench.delta_log
(
    product_id UInt64,
    event_hour DateTime('UTC'),
    count_delta Int64
)
ENGINE = MergeTree
ORDER BY (product_id, event_hour);

CREATE MATERIALIZED VIEW shop_a7_hybrid_bench.delta_mv
TO shop_a7_hybrid_bench.delta_log AS
WITH
candidates AS
(
    SELECT
        product_id,
        journey_id,
        min(occurred_at) AS candidate_at,
        groupUniqArray(ingest_row_id) AS block_ingest_ids
    FROM shop_a7_hybrid_bench.delta_raw
    GROUP BY product_id, journey_id
),
history_for_candidates AS
(
    SELECT *
    FROM shop_a7_hybrid_bench.delta_raw_history
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id FROM candidates
    )
),
evaluated AS
(
    SELECT
        c.product_id,
        c.journey_id,
        c.candidate_at,
        countIf(NOT has(c.block_ingest_ids, h.ingest_row_id)) AS history_count,
        minIf(toNullable(h.occurred_at), NOT has(c.block_ingest_ids, h.ingest_row_id)) AS previous_at
    FROM candidates AS c
    LEFT JOIN history_for_candidates AS h
        ON h.product_id = c.product_id
       AND h.journey_id = c.journey_id
    GROUP BY c.product_id, c.journey_id, c.candidate_at, c.block_ingest_ids
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
