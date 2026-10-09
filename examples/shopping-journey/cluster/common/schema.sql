-- A1~A6 조회 성능 비교에서 함께 사용하는 불변 원본 데이터셋이다.
-- 이 테이블에는 MV를 연결하지 않는다. 케이스별 파생 데이터는 각 DB로 backfill한다.

CREATE DATABASE IF NOT EXISTS shop_benchmark ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_benchmark.shopping_events_local ON CLUSTER 'cluster1'
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
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/shop_benchmark/shopping_events_local',
    '{replica}'
)
PARTITION BY toYYYYMM(received_at)
ORDER BY (product_id, journey_id, event_kind, occurred_at, message_id);

CREATE TABLE IF NOT EXISTS shop_benchmark.shopping_events ON CLUSTER 'cluster1'
AS shop_benchmark.shopping_events_local
ENGINE = Distributed(
    'cluster1',
    'shop_benchmark',
    'shopping_events_local',
    cityHash64(journey_id)
);
