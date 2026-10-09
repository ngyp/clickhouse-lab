-- A3: event에서 최초 이벤트를 조회 시점에 선별한 뒤 exact count
-- 파생 데이터를 저장하지 않고 각 shard의 로컬 View에서 먼저 집계한다.

CREATE DATABASE IF NOT EXISTS shop_a3 ON CLUSTER 'cluster1';

-- 전체 누적은 대표 이벤트의 속성이 필요하지 않으므로 고유 키만 선별한다.
CREATE VIEW IF NOT EXISTS shop_a3.event_counts_local ON CLUSTER 'cluster1' AS
SELECT
    product_id,
    event_kind,
    count() AS exact_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind
    FROM shop_benchmark.shopping_events_local
    GROUP BY product_id, journey_id, event_kind
)
GROUP BY product_id, event_kind;

CREATE TABLE IF NOT EXISTS shop_a3.event_counts ON CLUSTER 'cluster1'
AS shop_a3.event_counts_local
ENGINE = Distributed(
    'cluster1',
    'shop_a3',
    'event_counts_local',
    product_id
);

-- 시간별 귀속에는 대표 이벤트의 occurred_at만 보존한다.
CREATE VIEW IF NOT EXISTS shop_a3.hourly_counts_local ON CLUSTER 'cluster1' AS
SELECT
    product_id,
    toStartOfHour(first_occurred_at) AS hour_start,
    event_kind,
    count() AS exact_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMin(occurred_at, tuple(received_at, message_id)) AS first_occurred_at
    FROM shop_benchmark.shopping_events_local
    GROUP BY product_id, journey_id, event_kind
)
GROUP BY product_id, hour_start, event_kind;

CREATE TABLE IF NOT EXISTS shop_a3.hourly_counts ON CLUSTER 'cluster1'
AS shop_a3.hourly_counts_local
ENGINE = Distributed(
    'cluster1',
    'shop_a3',
    'hourly_counts_local',
    product_id
);

-- 고객 그룹 조회에 필요한 대표 속성만 하나의 Tuple로 보존한다.
CREATE VIEW IF NOT EXISTS shop_a3.customer_group_counts_local ON CLUSTER 'cluster1' AS
SELECT
    product_id,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    customer_group_id,
    event_kind,
    count() AS exact_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMin(
            tuple(mall_id, store_id, arrayDistinct(customer_group_ids)),
            tuple(received_at, message_id)
        ) AS representative
    FROM shop_benchmark.shopping_events_local
    GROUP BY product_id, journey_id, event_kind
)
ARRAY JOIN representative.3 AS customer_group_id
GROUP BY product_id, mall_id, store_id, customer_group_id, event_kind;

CREATE TABLE IF NOT EXISTS shop_a3.customer_group_counts ON CLUSTER 'cluster1'
AS shop_a3.customer_group_counts_local
ENGINE = Distributed(
    'cluster1',
    'shop_a3',
    'customer_group_counts_local',
    product_id
);
