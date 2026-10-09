-- 분산 상품 1개와 집중 상품의 숫자 누적 summary를 자동 판정한다.

SELECT
    'normal_product' AS test_case,
    notify_count,
    view_count,
    cart_count,
    click_count,
    purchase_count,
    notify_count = 100000
        AND view_count = 4000
        AND cart_count = 1000
        AND click_count = 5000
        AND purchase_count = 500 AS passed
FROM shop_a7_1.cumulative_summary_by_product(product_id = 1000000);

SELECT
    'hot_product' AS test_case,
    notify_count,
    view_count,
    cart_count,
    click_count,
    purchase_count,
    notify_count = 10000000
        AND view_count = 400000
        AND cart_count = 100000
        AND click_count = 500000
        AND purchase_count = 50000 AS passed
FROM shop_a7_1.cumulative_summary_by_product(product_id = 2000000);

-- 공통 원본 CLICK 중복 500건을 입력한 뒤 A7-1 FINAL에서는 더 이른 retry 행이 남아야 한다.
SELECT
    count() AS source_raw_rows,
    (SELECT count() FROM shop_a7_1.click_events FINAL WHERE product_id = 1000000) AS final_rows,
    (SELECT countIf(endsWith(message_id, '-click-retry'))
     FROM shop_a7_1.click_events FINAL WHERE product_id = 1000000) AS earlier_retry_winners,
    source_raw_rows = 5500
        AND final_rows = 5000
        AND earlier_retry_winners = 500 AS passed
FROM shop_benchmark.shopping_events
WHERE product_id = 1000000 AND event_kind = 'CLICK';

SELECT
    sum(queue_size) AS replication_queue,
    max(absolute_delay) AS max_replication_delay,
    min(active_replicas) AS min_active_replicas
FROM clusterAllReplicas('cluster1', system.replicas)
WHERE database = 'shop_a7_1';
