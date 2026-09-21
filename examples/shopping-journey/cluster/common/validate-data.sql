-- 공통 원본은 아래 검증을 모두 통과한 뒤 A1~A6에서 사용한다.

SELECT
    count() AS actual_raw_rows,
    22200000 AS expected_raw_rows,
    actual_raw_rows = expected_raw_rows AS passed
FROM shop_benchmark.shopping_events;

SELECT
    countDistinct(product_id) AS actual_products,
    101 AS expected_products,
    actual_products = expected_products AS passed
FROM shop_benchmark.shopping_events;

SELECT
    event_kind,
    count() AS actual_rows,
    transform(
        event_kind,
        ['NOTIFY', 'CLICK', 'VIEW', 'CART', 'PURCHASE'],
        [20000000, 1100000, 800000, 200000, 100000],
        toUInt64(0)
    ) AS expected_rows,
    actual_rows = expected_rows AS passed
FROM shop_benchmark.shopping_events
GROUP BY event_kind
ORDER BY event_kind;

-- 일반 상품 100개는 각각 111,000행이어야 한다.
SELECT
    count() AS actual_products,
    min(raw_rows) AS min_rows,
    max(raw_rows) AS max_rows,
    actual_products = 100 AND min_rows = 111000 AND max_rows = 111000 AS passed
FROM
(
    SELECT product_id, count() AS raw_rows
    FROM shop_benchmark.shopping_events
    WHERE product_id BETWEEN 1000000 AND 1000099
    GROUP BY product_id
);

-- 집중 상품은 11,100,000행이어야 한다.
SELECT
    count() AS actual_rows,
    11100000 AS expected_rows,
    actual_rows = expected_rows AS passed
FROM shop_benchmark.shopping_events
WHERE product_id = 2000000;

-- 같은 shard의 세 replica가 같은 행 수인지 확인한다.
SELECT
    hostName() AS host,
    count() AS rows
FROM clusterAllReplicas('cluster1', shop_benchmark.shopping_events_local)
GROUP BY host
ORDER BY host;

SELECT
    sum(queue_size) AS replication_queue,
    max(absolute_delay) AS max_replication_delay,
    min(active_replicas) AS min_active_replicas
FROM clusterAllReplicas('cluster1', system.replicas)
WHERE database = 'shop_benchmark';
