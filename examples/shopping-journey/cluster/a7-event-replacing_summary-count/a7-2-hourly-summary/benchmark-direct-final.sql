SELECT
    event_hour,
    countIf(event_type = 'NOTIFY') AS notify_count,
    countIf(event_type = 'VIEW') AS view_count,
    countIf(event_type = 'CART') AS cart_count,
    countIf(event_type = 'CLICK') AS click_count,
    countIf(event_type = 'PURCHASE') AS purchase_count
FROM
(
    SELECT 'NOTIFY' AS event_type, toStartOfHour(occurred_at) AS event_hour
    FROM shop_a7_1.notification_events FINAL WHERE product_id = 2000000
    UNION ALL
    SELECT 'VIEW', toStartOfHour(occurred_at)
    FROM shop_a7_1.view_events FINAL WHERE product_id = 2000000
    UNION ALL
    SELECT 'CART', toStartOfHour(occurred_at)
    FROM shop_a7_1.cart_events FINAL WHERE product_id = 2000000
    UNION ALL
    SELECT 'CLICK', toStartOfHour(occurred_at)
    FROM shop_a7_1.click_events FINAL WHERE product_id = 2000000
    UNION ALL
    SELECT 'PURCHASE', toStartOfHour(occurred_at)
    FROM shop_a7_1.purchase_events FINAL WHERE product_id = 2000000
)
GROUP BY event_hour
ORDER BY event_hour
FORMAT Null;
