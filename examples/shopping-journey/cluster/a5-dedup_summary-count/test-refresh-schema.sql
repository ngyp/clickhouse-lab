-- 정확 summary 전체 재생성의 벽시계 시간을 측정하는 임시 replicated target이다.

DROP DATABASE IF EXISTS shop_a5_refresh_test ON CLUSTER 'cluster1';
CREATE DATABASE shop_a5_refresh_test ON CLUSTER 'cluster1';

CREATE TABLE shop_a5_refresh_test.event_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    hour_start DateTime('UTC'),
    event_kind LowCardinality(String),
    event_count Int64
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a5_refresh_test/event_summary_local',
    '{replica}'
)
ORDER BY (mall_id, store_id, product_id, hour_start, event_kind);

CREATE TABLE shop_a5_refresh_test.customer_group_summary_local ON CLUSTER 'cluster1'
(
    mall_id UInt64,
    store_id UInt64,
    product_id UInt64,
    hour_start DateTime('UTC'),
    customer_group_id UInt64,
    event_kind LowCardinality(String),
    event_count Int64
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_a5_refresh_test/customer_group_summary_local',
    '{replica}'
)
ORDER BY (
    mall_id,
    store_id,
    product_id,
    hour_start,
    customer_group_id,
    event_kind
);
