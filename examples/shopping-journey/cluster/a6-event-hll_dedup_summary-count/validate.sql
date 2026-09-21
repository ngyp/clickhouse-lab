-- 전체 누적 HLL은 공통 원본에서 조회한다.
SELECT
    event_kind,
    uniqExact(journey_id) AS exact_count,
    uniqHLL12(journey_id) AS hll_count,
    round(
        abs(toInt64(hll_count) - toInt64(exact_count)) * 100.0 / exact_count,
        3
    ) AS relative_error_pct,
    relative_error_pct <= 3 AS passed
FROM shop_benchmark.shopping_events
GROUP BY event_kind
ORDER BY event_kind;

SELECT
    product_id,
    event_kind,
    uniqExact(journey_id) AS exact_count,
    uniqHLL12(journey_id) AS hll_count,
    round(
        abs(toInt64(hll_count) - toInt64(exact_count)) * 100.0 / exact_count,
        3
    ) AS relative_error_pct,
    relative_error_pct <= 3 AS passed
FROM shop_benchmark.shopping_events
WHERE product_id IN (1000000, 2000000)
GROUP BY product_id, event_kind
ORDER BY product_id, event_kind;

SELECT
    sum(event_count) AS actual_events,
    22100000 AS expected_events,
    actual_events = expected_events AS passed
FROM shop_a6.event_summary;

SELECT
    event_kind,
    sum(event_count) AS actual_count,
    transform(
        event_kind,
        ['NOTIFY', 'CLICK', 'VIEW', 'CART', 'PURCHASE'],
        [20000000, 1000000, 800000, 200000, 100000],
        toInt64(0)
    ) AS expected_count,
    actual_count = expected_count AS passed
FROM shop_a6.event_summary
GROUP BY event_kind
ORDER BY event_kind;

SELECT
    product_id,
    event_kind,
    sum(event_count) AS actual_count,
    multiIf(
        product_id = 2000000 AND event_kind = 'NOTIFY', 10000000,
        product_id = 2000000 AND event_kind = 'CLICK', 500000,
        product_id = 2000000 AND event_kind = 'VIEW', 400000,
        product_id = 2000000 AND event_kind = 'CART', 100000,
        product_id = 2000000 AND event_kind = 'PURCHASE', 50000,
        product_id = 1000000 AND event_kind = 'NOTIFY', 100000,
        product_id = 1000000 AND event_kind = 'CLICK', 5000,
        product_id = 1000000 AND event_kind = 'VIEW', 4000,
        product_id = 1000000 AND event_kind = 'CART', 1000,
        product_id = 1000000 AND event_kind = 'PURCHASE', 500,
        toInt64(0)
    ) AS expected_count,
    actual_count = expected_count AS passed
FROM shop_a6.event_summary
WHERE product_id IN (1000000, 2000000)
GROUP BY product_id, event_kind
ORDER BY product_id, event_kind;

SELECT
    sum(event_count) AS actual_group_memberships,
    44200000 AS expected_group_memberships,
    actual_group_memberships = expected_group_memberships AS passed
FROM shop_a6.customer_group_summary;

SELECT
    sum(queue_size) AS replication_queue,
    max(absolute_delay) AS max_replication_delay,
    min(active_replicas) AS min_active_replicas
FROM clusterAllReplicas('cluster1', system.replicas)
WHERE database = 'shop_a6';
