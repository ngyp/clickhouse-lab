-- A7-1 직접 FINAL 결과와 A7-2 시간 Summary의 전체 기간 합계가 같아야 한다.

SELECT
    'normal_product' AS test_case,
    sum(notify_count) AS notify_count,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count,
    notify_count = 100000
        AND view_count = 4000
        AND cart_count = 1000
        AND click_count = 5000
        AND purchase_count = 500 AS passed
FROM shop_a7_2.hourly_summary
WHERE product_id = 1000000;

SELECT
    'hot_product' AS test_case,
    sum(notify_count) AS notify_count,
    sum(view_count) AS view_count,
    sum(cart_count) AS cart_count,
    sum(click_count) AS click_count,
    sum(purchase_count) AS purchase_count,
    notify_count = 10000000
        AND view_count = 400000
        AND cart_count = 100000
        AND click_count = 500000
        AND purchase_count = 50000 AS passed
FROM shop_a7_2.hourly_summary
WHERE product_id = 2000000;

SELECT
    sum(queue_size) AS replication_queue,
    max(absolute_delay) AS max_replication_delay,
    min(active_replicas) AS min_active_replicas
FROM clusterAllReplicas('cluster1', system.replicas)
WHERE database = 'shop_a7_2';
