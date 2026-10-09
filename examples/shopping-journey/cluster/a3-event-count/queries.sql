-- product_id를 지정해 A3의 세 조회 경로를 확인한다.
-- 예: clickhouse-client --param_product_id=1000000 --multiquery < queries.sql

-- 1. 전체 누적 exact count
SELECT
    event_kind,
    sum(exact_count) AS exact_count
FROM shop_a3.event_counts
WHERE product_id = {product_id:UInt64}
GROUP BY event_kind
ORDER BY event_kind
SETTINGS optimize_aggregation_in_order = 1;

-- 2. 최초 이벤트 발생 시각 기준 시간별 exact count
SELECT
    hour_start,
    event_kind,
    sum(exact_count) AS exact_count
FROM shop_a3.hourly_counts
WHERE product_id = {product_id:UInt64}
GROUP BY hour_start, event_kind
ORDER BY hour_start, event_kind
SETTINGS optimize_aggregation_in_order = 1;

-- 3. 대표 이벤트의 고객 그룹별 exact count
SELECT
    mall_id,
    store_id,
    customer_group_id,
    event_kind,
    sum(exact_count) AS exact_count
FROM shop_a3.customer_group_counts
WHERE product_id = {product_id:UInt64}
GROUP BY mall_id, store_id, customer_group_id, event_kind
ORDER BY mall_id, store_id, customer_group_id, event_kind
SETTINGS optimize_aggregation_in_order = 1;
