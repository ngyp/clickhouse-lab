-- generate-performance-data.sql 실행 후 데이터 분포와 최초 event 선별 결과를 검증한다.

SELECT
    count() AS actual_raw_rows,
    22200000 AS expected_raw_rows,
    actual_raw_rows = expected_raw_rows AS passed
FROM shop_a2.shopping_events
WHERE startsWith(journey_id, 'perf-');

SELECT
    count() AS actual_representative_rows,
    22100000 AS expected_representative_rows,
    actual_representative_rows = expected_representative_rows AS passed
FROM shop_a2.first_events
WHERE startsWith(journey_id, 'perf-');

SELECT
    countDistinct(product_id) AS actual_products,
    101 AS expected_products,
    min(product_id) AS min_product_id,
    max(product_id) AS max_product_id
FROM shop_a2.first_events
WHERE startsWith(journey_id, 'perf-');

-- 일반 상품은 각각 원본 111,000행, 대표 110,500행이어야 한다.
SELECT
    min(raw_rows) AS min_raw_rows_per_product,
    max(raw_rows) AS max_raw_rows_per_product,
    111000 AS expected_raw_rows_per_product
FROM
(
    SELECT product_id, count() AS raw_rows
    FROM shop_a2.shopping_events
    WHERE product_id BETWEEN 1000000 AND 1000099
    GROUP BY product_id
);

SELECT
    min(representative_rows) AS min_representative_rows_per_product,
    max(representative_rows) AS max_representative_rows_per_product,
    110500 AS expected_representative_rows_per_product
FROM
(
    SELECT product_id, count() AS representative_rows
    FROM shop_a2.first_events
    WHERE product_id BETWEEN 1000000 AND 1000099
    GROUP BY product_id
);

-- 집중 상품은 원본 11,100,000행, 대표 11,050,000행이어야 한다.
SELECT
    (SELECT count() FROM shop_a2.shopping_events WHERE product_id = 2000000) AS hot_raw_rows,
    11100000 AS expected_hot_raw_rows,
    (SELECT count() FROM shop_a2.first_events WHERE product_id = 2000000) AS hot_representative_rows,
    11050000 AS expected_hot_representative_rows;

-- 대표 event 기준 이벤트별 정확 count와 원본 HLL 오차를 비교한다.
SELECT
    exact.event_kind,
    exact.exact_journeys,
    approximate.hll_journeys,
    round(
        abs(toFloat64(approximate.hll_journeys) - toFloat64(exact.exact_journeys))
            / exact.exact_journeys * 100,
        3
    ) AS relative_error_percent
FROM
(
    SELECT event_kind, count() AS exact_journeys
    FROM shop_a2.first_events
    WHERE startsWith(journey_id, 'perf-')
    GROUP BY event_kind
) AS exact
INNER JOIN
(
    SELECT event_kind, uniqHLL12(journey_id) AS hll_journeys
    FROM shop_a2.shopping_events
    WHERE startsWith(journey_id, 'perf-')
    GROUP BY event_kind
) AS approximate USING (event_kind)
ORDER BY event_kind;
