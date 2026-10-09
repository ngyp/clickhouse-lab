-- A7-1: 이벤트별 ReplacingMergeTree + 정수 delta 누적 summary
-- 시간별 summary와 exact aggregate state는 이 실험에서 제외한다.
-- count_delta는 입력 처리기가 이 행을 누적 count에 더할 값이다(최초 1, 이후 0).
-- 같은 (event_kind, product_id, journey_id)는 한 처리 경로에서 순차 판정해야 한다.

CREATE DATABASE IF NOT EXISTS shop_a7_1 ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_a7_1.view_events_local ON CLUSTER 'cluster1'
(
    message_id String,
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    journey_id String,
    customer_group_ids Array(UInt64),
    source_kind LowCardinality(String),
    occurred_at DateTime64(3, 'UTC'),
    received_at DateTime64(3, 'UTC'),
    count_delta UInt8,
    first_version UInt64 MATERIALIZED bitNot(toUInt64(toUnixTimestamp64Milli(occurred_at)))
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/view_events_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.view_events ON CLUSTER 'cluster1'
AS shop_a7_1.view_events_local
ENGINE = Distributed('cluster1', 'shop_a7_1', 'view_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_1.cart_events_local ON CLUSTER 'cluster1'
AS shop_a7_1.view_events_local
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/cart_events_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.cart_events ON CLUSTER 'cluster1'
AS shop_a7_1.cart_events_local
ENGINE = Distributed('cluster1', 'shop_a7_1', 'cart_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_1.click_events_local ON CLUSTER 'cluster1'
AS shop_a7_1.view_events_local
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/click_events_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.click_events ON CLUSTER 'cluster1'
AS shop_a7_1.click_events_local
ENGINE = Distributed('cluster1', 'shop_a7_1', 'click_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_1.purchase_events_local ON CLUSTER 'cluster1'
AS shop_a7_1.view_events_local
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/purchase_events_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.purchase_events ON CLUSTER 'cluster1'
AS shop_a7_1.purchase_events_local
ENGINE = Distributed('cluster1', 'shop_a7_1', 'purchase_events_local', cityHash64(journey_id));

CREATE TABLE IF NOT EXISTS shop_a7_1.notification_events_local ON CLUSTER 'cluster1'
AS shop_a7_1.view_events_local
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/notification_events_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.notification_events ON CLUSTER 'cluster1'
AS shop_a7_1.notification_events_local
ENGINE = Distributed('cluster1', 'shop_a7_1', 'notification_events_local', cityHash64(journey_id));

-- MV는 기존 summary 행을 UPDATE하지 않고 아래 숫자 delta 행을 추가한다.
-- 동일 키 행은 background merge에서 합쳐지며 조회는 merge 전후 정확성을 위해 sum()한다.
CREATE TABLE IF NOT EXISTS shop_a7_1.cumulative_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    notify_count UInt64,
    view_count UInt64,
    cart_count UInt64,
    click_count UInt64,
    purchase_count UInt64
)
ENGINE = ReplicatedSummingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_1/cumulative_summary_local',
    '{replica}'
)
ORDER BY (product_id, mall_id, store_id);

CREATE TABLE IF NOT EXISTS shop_a7_1.cumulative_summary ON CLUSTER 'cluster1'
AS shop_a7_1.cumulative_summary_local
ENGINE = Distributed(
    'cluster1',
    'shop_a7_1',
    'cumulative_summary_local',
    cityHash64(product_id)
);

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_1.view_summary_mv ON CLUSTER 'cluster1'
TO shop_a7_1.cumulative_summary_local AS
SELECT mall_id, store_id, product_id,
       toUInt64(0) AS notify_count, toUInt64(sum(count_delta)) AS view_count,
       toUInt64(0) AS cart_count, toUInt64(0) AS click_count,
       toUInt64(0) AS purchase_count
FROM shop_a7_1.view_events_local
WHERE count_delta > 0
GROUP BY mall_id, store_id, product_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_1.cart_summary_mv ON CLUSTER 'cluster1'
TO shop_a7_1.cumulative_summary_local AS
SELECT mall_id, store_id, product_id,
       toUInt64(0) AS notify_count, toUInt64(0) AS view_count,
       toUInt64(sum(count_delta)) AS cart_count, toUInt64(0) AS click_count,
       toUInt64(0) AS purchase_count
FROM shop_a7_1.cart_events_local
WHERE count_delta > 0
GROUP BY mall_id, store_id, product_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_1.click_summary_mv ON CLUSTER 'cluster1'
TO shop_a7_1.cumulative_summary_local AS
SELECT mall_id, store_id, product_id,
       toUInt64(0) AS notify_count, toUInt64(0) AS view_count,
       toUInt64(0) AS cart_count, toUInt64(sum(count_delta)) AS click_count,
       toUInt64(0) AS purchase_count
FROM shop_a7_1.click_events_local
WHERE count_delta > 0
GROUP BY mall_id, store_id, product_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_1.purchase_summary_mv ON CLUSTER 'cluster1'
TO shop_a7_1.cumulative_summary_local AS
SELECT mall_id, store_id, product_id,
       toUInt64(0) AS notify_count, toUInt64(0) AS view_count,
       toUInt64(0) AS cart_count, toUInt64(0) AS click_count,
       toUInt64(sum(count_delta)) AS purchase_count
FROM shop_a7_1.purchase_events_local
WHERE count_delta > 0
GROUP BY mall_id, store_id, product_id;

-- 공통 benchmark는 여정 단위 NOTIFY 상세 행을 제공한다.
-- 운영의 S3 사전 집계 notification_count 직접 합산은 별도 후속 실험이다.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a7_1.notification_summary_mv ON CLUSTER 'cluster1'
TO shop_a7_1.cumulative_summary_local AS
SELECT mall_id, store_id, product_id,
       toUInt64(sum(count_delta)) AS notify_count, toUInt64(0) AS view_count,
       toUInt64(0) AS cart_count, toUInt64(0) AS click_count,
       toUInt64(0) AS purchase_count
FROM shop_a7_1.notification_events_local
WHERE count_delta > 0
GROUP BY mall_id, store_id, product_id;

-- 애플리케이션은 이 parameterized View를 완성된 누적 summary처럼 조회한다.
-- 내부 sum은 아직 merge되지 않은 delta와 shard별 부분 count를 합친다.
CREATE VIEW IF NOT EXISTS shop_a7_1.cumulative_summary_by_product ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    sum(notify_count) AS notify_count,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count
FROM shop_a7_1.cumulative_summary
WHERE product_id = {product_id:UInt64}
GROUP BY mall_id, store_id, product_id;
