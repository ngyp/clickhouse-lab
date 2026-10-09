-- 예: clickhouse-client --param_product_id=1000000 --multiquery < queries.sql
-- 애플리케이션은 내부 delta 합산을 감춘 parameterized View를 한 행 summary처럼 조회한다.

SELECT
    mall_id,
    store_id,
    product_id,
    notify_count,
    view_count,
    cart_count,
    click_count,
    purchase_count
FROM shop_a7_1.cumulative_summary_by_product(product_id = {product_id:UInt64});
