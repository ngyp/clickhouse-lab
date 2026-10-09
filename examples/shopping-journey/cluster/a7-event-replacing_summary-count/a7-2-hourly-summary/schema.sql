-- A7-2: 최초 이벤트 상태 + signed delta 시간 Summary
-- 실시간 입력 처리기는 (event_type, product_id, journey_id)로 현재 상태를 조회한 뒤
-- 신규 +1, 무시, 또는 이전 시간 -1/새 시간 +1을 결정한다.

CREATE DATABASE IF NOT EXISTS shop_a7_2 ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_a7_2.first_event_state_local ON CLUSTER 'cluster1'
(
    event_type LowCardinality(String),
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    journey_id String,
    customer_group_ids Array(UInt64),
    first_occurred_at DateTime64(3, 'UTC'),
    first_version UInt64 MATERIALIZED bitNot(toUInt64(toUnixTimestamp64Milli(first_occurred_at)))
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_2/first_event_state_local',
    '{replica}',
    first_version
)
ORDER BY (product_id, event_type, journey_id);

CREATE TABLE IF NOT EXISTS shop_a7_2.first_event_state ON CLUSTER 'cluster1'
AS shop_a7_2.first_event_state_local
ENGINE = Distributed(
    'cluster1',
    'shop_a7_2',
    'first_event_state_local',
    cityHash64(journey_id)
);

-- 시간 이동 보정에 -1이 필요하므로 count 열은 Int64다.
CREATE TABLE IF NOT EXISTS shop_a7_2.hourly_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    event_hour DateTime('UTC'),
    notify_count Int64,
    view_count Int64,
    cart_count Int64,
    click_count Int64,
    purchase_count Int64
)
ENGINE = ReplicatedSummingMergeTree(
    '/clickhouse/tables/{shard}/shop_a7_2/hourly_summary_local',
    '{replica}'
)
PARTITION BY toYYYYMM(event_hour)
ORDER BY (product_id, event_hour, mall_id, store_id);

CREATE TABLE IF NOT EXISTS shop_a7_2.hourly_summary ON CLUSTER 'cluster1'
AS shop_a7_2.hourly_summary_local
ENGINE = Distributed(
    'cluster1',
    'shop_a7_2',
    'hourly_summary_local',
    cityHash64(product_id)
);

-- background merge 전 delta 행과 shard별 부분 합계를 조회 시점에 완성한다.
-- backfill의 부분 합계는 journey_id가 있던 기존 shard에 남을 수 있으므로
-- 이 View에는 optimize_skip_unused_shards=1을 적용하지 않는다.
CREATE VIEW IF NOT EXISTS shop_a7_2.hourly_summary_by_product ON CLUSTER 'cluster1' AS
SELECT
    mall_id,
    store_id,
    product_id,
    event_hour,
    sum(notify_count) AS notify_count,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count
FROM shop_a7_2.hourly_summary
WHERE product_id = {product_id:UInt64}
  AND event_hour >= {from_hour:DateTime}
  AND event_hour < {to_hour:DateTime}
GROUP BY mall_id, store_id, product_id, event_hour
HAVING notify_count != 0
    OR view_count != 0
    OR cart_count != 0
    OR click_count != 0
    OR purchase_count != 0;
