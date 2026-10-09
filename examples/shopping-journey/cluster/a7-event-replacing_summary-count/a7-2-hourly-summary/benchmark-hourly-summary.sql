SELECT
    event_hour,
    sum(notify_count),
    sum(view_count),
    sum(cart_count),
    sum(click_count),
    sum(purchase_count)
FROM shop_a7_2.hourly_summary
WHERE product_id = 2000000
GROUP BY event_hour
ORDER BY event_hour
FORMAT Null;
