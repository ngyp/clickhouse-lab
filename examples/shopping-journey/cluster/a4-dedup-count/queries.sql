-- product_id를 지정해 A4의 세 exact 조회 경로를 확인한다.
-- 예: clickhouse-client --param_product_id=1000000 --multiquery < queries.sql

-- 1. 전체 누적 exact count
SELECT
    event_kind,
    count() AS exact_count
FROM shop_a4.first_events_by_product(product_id = {product_id:UInt64})
GROUP BY event_kind
ORDER BY event_kind;

-- 2. 최초 이벤트 발생 시각 기준 시간별 exact count
SELECT
    toStartOfHour(occurred_at) AS hour_start,
    event_kind,
    count() AS exact_count
FROM shop_a4.first_events_by_product(product_id = {product_id:UInt64})
GROUP BY hour_start, event_kind
ORDER BY hour_start, event_kind;

-- 3. 대표 이벤트의 고객 그룹별 exact count
SELECT
    mall_id,
    store_id,
    customer_group_id,
    event_kind,
    count() AS exact_count
FROM shop_a4.first_events_by_product(product_id = {product_id:UInt64})
ARRAY JOIN arrayDistinct(customer_group_ids) AS customer_group_id
GROUP BY mall_id, store_id, customer_group_id, event_kind
ORDER BY mall_id, store_id, customer_group_id, event_kind;
