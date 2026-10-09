-- 이벤트별 선택 정책을 혼합하는 A7 실험.
-- VIEW/CLICK은 최초 입수 고정, CART/PURCHASE는 가장 빠른 발생 시각을 사용한다.

CREATE DATABASE IF NOT EXISTS shop_a7_hybrid ON CLUSTER 'cluster1';

-- 원본 이벤트 공통 형상 -------------------------------------------------------

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.view_events_local ON CLUSTER 'cluster1'
(
    ingest_row_id UUID DEFAULT generateUUIDv4(),
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    journey_id String,
    customer_group_ids Array(UInt64),
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC')
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/view_events_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, received_at, ingest_row_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.click_events_local ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_events_local
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/click_events_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, received_at, ingest_row_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.cart_events_local ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_events_local
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/cart_events_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, occurred_at, ingest_row_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.purchase_events_local ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_events_local
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/purchase_events_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, occurred_at, ingest_row_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.view_events ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_events_local
ENGINE = Distributed('cluster1', 'shop_a7_hybrid', 'view_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.click_events ON CLUSTER 'cluster1'
AS shop_a7_hybrid.click_events_local
ENGINE = Distributed('cluster1', 'shop_a7_hybrid', 'click_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.cart_events ON CLUSTER 'cluster1'
AS shop_a7_hybrid.cart_events_local
ENGINE = Distributed('cluster1', 'shop_a7_hybrid', 'cart_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.purchase_events ON CLUSTER 'cluster1'
AS shop_a7_hybrid.purchase_events_local
ENGINE = Distributed('cluster1', 'shop_a7_hybrid', 'purchase_events_local', cityHash64(journey_id));

-- 최초 입수 고정 경로 --------------------------------------------------------

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.view_first_received_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    journey_id String,
    customer_group_ids Array(UInt64),
    occurred_at DateTime64(3, 'UTC'),
    first_received_at DateTime64(3, 'UTC')
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/view_first_received_local',
    '{replica}'
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.click_first_received_local ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_first_received_local
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/click_first_received_local',
    '{replica}'
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.view_first_received ON CLUSTER 'cluster1'
AS shop_a7_hybrid.view_first_received_local
ENGINE = Distributed(
    'cluster1', 'shop_a7_hybrid', 'view_first_received_local', cityHash64(journey_id)
);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.click_first_received ON CLUSTER 'cluster1'
AS shop_a7_hybrid.click_first_received_local
ENGINE = Distributed(
    'cluster1', 'shop_a7_hybrid', 'click_first_received_local', cityHash64(journey_id)
);

-- 한 INSERT block 안에서는 received_at이 가장 빠른 후보 하나만 선택한다.
-- 이전 block에서 이미 승인된 키는 target 테이블의 후보 키 조회로 제외한다.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_hybrid.view_first_received_mv ON CLUSTER 'cluster1'
TO shop_a7_hybrid.view_first_received_local AS
WITH candidates AS
(
    SELECT
        product_id,
        journey_id,
        argMin(
            tuple(mall_id, store_id, customer_group_ids, occurred_at, received_at),
            tuple(received_at, ingest_row_id)
        ) AS candidate
    FROM shop_a7_hybrid.view_events_local
    GROUP BY product_id, journey_id
),
existing_keys AS
(
    SELECT product_id, journey_id
    FROM shop_a7_hybrid.view_first_received_local
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id
        FROM candidates
    )
)
SELECT
    candidate.1 AS mall_id,
    candidate.2 AS store_id,
    c.product_id,
    c.journey_id,
    candidate.3 AS customer_group_ids,
    candidate.4 AS occurred_at,
    candidate.5 AS first_received_at
FROM candidates AS c
LEFT ANTI JOIN existing_keys AS e
    ON e.product_id = c.product_id
   AND e.journey_id = c.journey_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_hybrid.click_first_received_mv ON CLUSTER 'cluster1'
TO shop_a7_hybrid.click_first_received_local AS
WITH candidates AS
(
    SELECT
        product_id,
        journey_id,
        argMin(
            tuple(mall_id, store_id, customer_group_ids, occurred_at, received_at),
            tuple(received_at, ingest_row_id)
        ) AS candidate
    FROM shop_a7_hybrid.click_events_local
    GROUP BY product_id, journey_id
),
existing_keys AS
(
    SELECT product_id, journey_id
    FROM shop_a7_hybrid.click_first_received_local
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id
        FROM candidates
    )
)
SELECT
    candidate.1 AS mall_id,
    candidate.2 AS store_id,
    c.product_id,
    c.journey_id,
    candidate.3 AS customer_group_ids,
    candidate.4 AS occurred_at,
    candidate.5 AS first_received_at
FROM candidates AS c
LEFT ANTI JOIN existing_keys AS e
    ON e.product_id = c.product_id
   AND e.journey_id = c.journey_id;

-- 교체 가능한 최초 발생 경로 --------------------------------------------------

-- CART/PURCHASE가 함께 쓰는 signed delta 로그다. 물리 Summary가 아니므로
-- MergeTree에 그대로 보관하고 View에서 합산한다.
CREATE TABLE IF NOT EXISTS shop_a7_hybrid.event_summary_delta_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    event_type LowCardinality(String),
    event_hour DateTime('UTC'),
    count_delta Int64
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_hybrid/event_summary_delta_local',
    '{replica}'
)
PARTITION BY toYYYYMM(event_hour)
ORDER BY (product_id, event_type, event_hour, mall_id, store_id);

CREATE TABLE IF NOT EXISTS shop_a7_hybrid.event_summary_delta ON CLUSTER 'cluster1'
AS shop_a7_hybrid.event_summary_delta_local
ENGINE = Distributed(
    'cluster1', 'shop_a7_hybrid', 'event_summary_delta_local', cityHash64(product_id)
);

-- 전체 이력을 명시적으로 읽기 위한 일반 View다. MV source의 현재 block과 다르다.
CREATE VIEW IF NOT EXISTS shop_a7_hybrid.cart_events_history_local ON CLUSTER 'cluster1' AS
SELECT * FROM shop_a7_hybrid.cart_events_local;

CREATE VIEW IF NOT EXISTS shop_a7_hybrid.purchase_events_history_local ON CLUSTER 'cluster1' AS
SELECT * FROM shop_a7_hybrid.purchase_events_local;

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_hybrid.cart_delta_mv ON CLUSTER 'cluster1'
TO shop_a7_hybrid.event_summary_delta_local AS
WITH
candidates AS
(
    SELECT
        mall_id,
        store_id,
        product_id,
        journey_id,
        min(occurred_at) AS candidate_at,
        groupUniqArray(ingest_row_id) AS block_ingest_ids
    FROM shop_a7_hybrid.cart_events_local
    GROUP BY mall_id, store_id, product_id, journey_id
),
history_for_candidates AS
(
    SELECT *
    FROM shop_a7_hybrid.cart_events_history_local
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id FROM candidates
    )
),
evaluated AS
(
    SELECT
        c.mall_id,
        c.store_id,
        c.product_id,
        c.journey_id,
        c.candidate_at,
        countIf(NOT has(c.block_ingest_ids, h.ingest_row_id)) AS history_count,
        minIf(toNullable(h.occurred_at), NOT has(c.block_ingest_ids, h.ingest_row_id)) AS previous_at
    FROM candidates AS c
    LEFT JOIN history_for_candidates AS h
        ON h.product_id = c.product_id
       AND h.journey_id = c.journey_id
    GROUP BY
        c.mall_id, c.store_id, c.product_id, c.journey_id,
        c.candidate_at, c.block_ingest_ids
)
SELECT
    mall_id,
    store_id,
    product_id,
    'CART' AS event_type,
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

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_hybrid.purchase_delta_mv ON CLUSTER 'cluster1'
TO shop_a7_hybrid.event_summary_delta_local AS
WITH
candidates AS
(
    SELECT
        mall_id,
        store_id,
        product_id,
        journey_id,
        min(occurred_at) AS candidate_at,
        groupUniqArray(ingest_row_id) AS block_ingest_ids
    FROM shop_a7_hybrid.purchase_events_local
    GROUP BY mall_id, store_id, product_id, journey_id
),
history_for_candidates AS
(
    SELECT *
    FROM shop_a7_hybrid.purchase_events_history_local
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id FROM candidates
    )
),
evaluated AS
(
    SELECT
        c.mall_id,
        c.store_id,
        c.product_id,
        c.journey_id,
        c.candidate_at,
        countIf(NOT has(c.block_ingest_ids, h.ingest_row_id)) AS history_count,
        minIf(toNullable(h.occurred_at), NOT has(c.block_ingest_ids, h.ingest_row_id)) AS previous_at
    FROM candidates AS c
    LEFT JOIN history_for_candidates AS h
        ON h.product_id = c.product_id
       AND h.journey_id = c.journey_id
    GROUP BY
        c.mall_id, c.store_id, c.product_id, c.journey_id,
        c.candidate_at, c.block_ingest_ids
)
SELECT
    mall_id,
    store_id,
    product_id,
    'PURCHASE' AS event_type,
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

-- 통합 조회 계층 --------------------------------------------------------------

-- 단일 shard의 처리 결과와 MV 정확성을 검사하는 local View다.
CREATE VIEW IF NOT EXISTS shop_a7_hybrid.hourly_summary_local_view ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    event_hour,
    sumIf(event_count, event_type = 'VIEW') AS view_count,
    sumIf(event_count, event_type = 'CART') AS cart_count,
    sumIf(event_count, event_type = 'CLICK') AS click_count,
    sumIf(event_count, event_type = 'PURCHASE') AS purchase_count
FROM
(
    SELECT
        mall_id,
        store_id,
        product_id,
        toDateTime(toStartOfHour(occurred_at), 'UTC') AS event_hour,
        'VIEW' AS event_type,
        toInt64(count()) AS event_count
    FROM shop_a7_hybrid.view_first_received_local
    GROUP BY mall_id, store_id, product_id, event_hour

    UNION ALL

    SELECT
        mall_id,
        store_id,
        product_id,
        toDateTime(toStartOfHour(occurred_at), 'UTC') AS event_hour,
        'CLICK' AS event_type,
        toInt64(count()) AS event_count
    FROM shop_a7_hybrid.click_first_received_local
    GROUP BY mall_id, store_id, product_id, event_hour

    UNION ALL

    SELECT
        mall_id,
        store_id,
        product_id,
        event_hour,
        event_type,
        sum(count_delta) AS event_count
    FROM shop_a7_hybrid.event_summary_delta_local
    GROUP BY mall_id, store_id, product_id, event_hour, event_type
    HAVING event_count != 0
)
GROUP BY mall_id, store_id, product_id, event_hour
HAVING view_count != 0
    OR cart_count != 0
    OR click_count != 0
    OR purchase_count != 0;

CREATE VIEW IF NOT EXISTS shop_a7_hybrid.cumulative_summary_local_view ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count
FROM shop_a7_hybrid.hourly_summary_local_view
GROUP BY mall_id, store_id, product_id;

-- 애플리케이션용 분산 View다. XML 사용자 cluster_internal에는
-- shop_a7_hybrid의 local 테이블 SELECT 권한이 별도로 필요하다.
CREATE VIEW IF NOT EXISTS shop_a7_hybrid.hourly_summary_view ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    event_hour,
    sumIf(event_count, event_type = 'VIEW') AS view_count,
    sumIf(event_count, event_type = 'CART') AS cart_count,
    sumIf(event_count, event_type = 'CLICK') AS click_count,
    sumIf(event_count, event_type = 'PURCHASE') AS purchase_count
FROM
(
    SELECT
        mall_id,
        store_id,
        product_id,
        toDateTime(toStartOfHour(occurred_at), 'UTC') AS event_hour,
        'VIEW' AS event_type,
        toInt64(count()) AS event_count
    FROM shop_a7_hybrid.view_first_received
    GROUP BY mall_id, store_id, product_id, event_hour

    UNION ALL

    SELECT
        mall_id,
        store_id,
        product_id,
        toDateTime(toStartOfHour(occurred_at), 'UTC') AS event_hour,
        'CLICK' AS event_type,
        toInt64(count()) AS event_count
    FROM shop_a7_hybrid.click_first_received
    GROUP BY mall_id, store_id, product_id, event_hour

    UNION ALL

    SELECT
        mall_id,
        store_id,
        product_id,
        event_hour,
        event_type,
        sum(count_delta) AS event_count
    FROM shop_a7_hybrid.event_summary_delta
    GROUP BY mall_id, store_id, product_id, event_hour, event_type
    HAVING event_count != 0
)
GROUP BY mall_id, store_id, product_id, event_hour
HAVING view_count != 0
    OR cart_count != 0
    OR click_count != 0
    OR purchase_count != 0;

CREATE VIEW IF NOT EXISTS shop_a7_hybrid.cumulative_summary_view ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count
FROM shop_a7_hybrid.hourly_summary_view
GROUP BY mall_id, store_id, product_id;
