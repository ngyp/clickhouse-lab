-- 단순 chained MV가 A5의 대표 변경 보정을 만족하지 못하는 것을 재현한다.
-- 테스트 전용 단일 노드 DB이며 실행할 때마다 초기화한다.

DROP DATABASE IF EXISTS shop_a5_realtime_test;
CREATE DATABASE shop_a5_realtime_test;

CREATE TABLE shop_a5_realtime_test.events
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

CREATE TABLE shop_a5_realtime_test.states
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

CREATE MATERIALIZED VIEW shop_a5_realtime_test.events_to_states
TO shop_a5_realtime_test.states
AS
SELECT
    product_id,
    journey_id,
    event_kind,
    argMinState(
        tuple(occurred_at, message_id),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_a5_realtime_test.events
GROUP BY product_id, journey_id, event_kind;

CREATE TABLE shop_a5_realtime_test.naive_summary
(
    product_id UInt64,
    hour_start DateTime('UTC'),
    event_kind LowCardinality(String),
    event_count Int64
)
ENGINE = SummingMergeTree
ORDER BY (product_id, hour_start, event_kind);

CREATE MATERIALIZED VIEW shop_a5_realtime_test.states_to_summary
TO shop_a5_realtime_test.naive_summary
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
    FROM shop_a5_realtime_test.states
    GROUP BY product_id, journey_id, event_kind
)
GROUP BY product_id, hour_start, event_kind;

-- 최초 대표 이벤트.
INSERT INTO shop_a5_realtime_test.events VALUES
('original', 1, 'journey-1', 'CLICK',
 '2026-01-01 10:00:00.000', '2026-01-01 10:01:00.000');

-- 동일 메시지 재전송.
INSERT INTO shop_a5_realtime_test.events VALUES
('original', 1, 'journey-1', 'CLICK',
 '2026-01-01 10:00:00.000', '2026-01-01 10:01:00.000');

-- 더 이른 received_at을 가진 이벤트가 늦게 도착해 대표가 09시로 바뀐다.
INSERT INTO shop_a5_realtime_test.events VALUES
('late-earlier', 1, 'journey-1', 'CLICK',
 '2026-01-01 09:00:00.000', '2026-01-01 09:01:00.000');

SELECT
    count() AS raw_rows,
    3 AS expected_raw_rows,
    raw_rows = expected_raw_rows AS passed
FROM shop_a5_realtime_test.events;

SELECT
    representative.2 AS representative_message_id,
    representative.1 AS representative_occurred_at,
    representative_message_id = 'late-earlier' AS passed
FROM
(
    SELECT argMinMerge(first_event_state) AS representative
    FROM shop_a5_realtime_test.states
);

SELECT
    hour_start,
    sum(event_count) AS naive_count
FROM shop_a5_realtime_test.naive_summary
GROUP BY hour_start
ORDER BY hour_start;

SELECT
    sum(event_count) AS naive_total,
    1 AS expected_total,
    naive_total = expected_total AS passed
FROM shop_a5_realtime_test.naive_summary;
