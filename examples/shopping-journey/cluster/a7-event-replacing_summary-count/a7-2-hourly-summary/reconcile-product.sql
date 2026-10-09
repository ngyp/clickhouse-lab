-- 사용법: clickhouse-client --param_product_id=2000000 --multiquery < reconcile-product.sql
-- 이벤트별 FINAL 정답과 현재 시간 Summary의 차이만 signed delta로 추가한다.
-- 같은 product의 보정 작업은 동시에 실행하지 않는다. 실시간 입력과 겹친 오차는 다음 실행에서 수렴한다.
-- hourly_summary의 부분 합계가 여러 shard에 있을 수 있으므로 actual 조회에
-- optimize_skip_unused_shards=1을 적용하지 않는다.

SET join_use_nulls = 1;

INSERT INTO shop_a7_2.hourly_summary
    (mall_id, store_id, product_id, event_hour,
     notify_count, view_count, cart_count, click_count, purchase_count)
WITH
expected AS
(
    SELECT
        mall_id,
        store_id,
        product_id,
        event_hour,
        toInt64(countIf(event_type = 'NOTIFY')) AS notify_count,
        toInt64(countIf(event_type = 'VIEW')) AS view_count,
        toInt64(countIf(event_type = 'CART')) AS cart_count,
        toInt64(countIf(event_type = 'CLICK')) AS click_count,
        toInt64(countIf(event_type = 'PURCHASE')) AS purchase_count
    FROM
    (
        SELECT 'NOTIFY' AS event_type, mall_id, store_id, product_id,
               toStartOfHour(occurred_at) AS event_hour
        FROM shop_a7_1.notification_events FINAL
        WHERE product_id = {product_id:UInt64}
        UNION ALL
        SELECT 'VIEW', mall_id, store_id, product_id, toStartOfHour(occurred_at)
        FROM shop_a7_1.view_events FINAL
        WHERE product_id = {product_id:UInt64}
        UNION ALL
        SELECT 'CART', mall_id, store_id, product_id, toStartOfHour(occurred_at)
        FROM shop_a7_1.cart_events FINAL
        WHERE product_id = {product_id:UInt64}
        UNION ALL
        SELECT 'CLICK', mall_id, store_id, product_id, toStartOfHour(occurred_at)
        FROM shop_a7_1.click_events FINAL
        WHERE product_id = {product_id:UInt64}
        UNION ALL
        SELECT 'PURCHASE', mall_id, store_id, product_id, toStartOfHour(occurred_at)
        FROM shop_a7_1.purchase_events FINAL
        WHERE product_id = {product_id:UInt64}
    )
    GROUP BY mall_id, store_id, product_id, event_hour
),
actual AS
(
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
    GROUP BY mall_id, store_id, product_id, event_hour
)
SELECT
    mall_id,
    store_id,
    product_id,
    event_hour,
    notify_delta,
    view_delta,
    cart_delta,
    click_delta,
    purchase_delta
FROM
(
    SELECT
        coalesce(expected.mall_id, actual.mall_id) AS mall_id,
        coalesce(expected.store_id, actual.store_id) AS store_id,
        coalesce(expected.product_id, actual.product_id) AS product_id,
        coalesce(expected.event_hour, actual.event_hour) AS event_hour,
        coalesce(expected.notify_count, 0) - coalesce(actual.notify_count, 0) AS notify_delta,
        coalesce(expected.view_count, 0) - coalesce(actual.view_count, 0) AS view_delta,
        coalesce(expected.cart_count, 0) - coalesce(actual.cart_count, 0) AS cart_delta,
        coalesce(expected.click_count, 0) - coalesce(actual.click_count, 0) AS click_delta,
        coalesce(expected.purchase_count, 0) - coalesce(actual.purchase_count, 0) AS purchase_delta
    FROM expected
    FULL OUTER JOIN actual
        ON expected.mall_id = actual.mall_id
       AND expected.store_id = actual.store_id
       AND expected.product_id = actual.product_id
       AND expected.event_hour = actual.event_hour
)
WHERE notify_delta != 0
   OR view_delta != 0
   OR cart_delta != 0
   OR click_delta != 0
   OR purchase_delta != 0;
