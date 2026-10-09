-- 분산 상품 1개의 이벤트별 기대값을 자동 판정한다.

WITH expected AS
(
    SELECT
        item.1 AS event_kind,
        item.2 AS expected_count
    FROM
    (
        SELECT arrayJoin([
            tuple('NOTIFY', toUInt64(100000)),
            tuple('CLICK', toUInt64(5000)),
            tuple('VIEW', toUInt64(4000)),
            tuple('CART', toUInt64(1000)),
            tuple('PURCHASE', toUInt64(500))
        ]) AS item
    )
)
SELECT
    expected.event_kind AS event_kind,
    expected.expected_count AS expected_count,
    actual.exact_count AS actual_count,
    expected_count = actual_count AS passed
FROM expected
LEFT JOIN
(
    SELECT
        event_kind,
        sum(exact_count) AS exact_count
    FROM shop_a3.event_counts
    WHERE product_id = 1000000
    GROUP BY event_kind
) AS actual USING event_kind
ORDER BY event_kind;

-- 세 shard의 시간별 부분 집계를 최종 합산한 값도 같은 누적값이어야 한다.
SELECT
    event_kind,
    sum(exact_count) AS hourly_total,
    transform(
        event_kind,
        ['NOTIFY', 'CLICK', 'VIEW', 'CART', 'PURCHASE'],
        [100000, 5000, 4000, 1000, 500],
        toUInt64(0)
    ) AS expected_count,
    hourly_total = expected_count AS passed
FROM shop_a3.hourly_counts
WHERE product_id = 1000000
GROUP BY event_kind
ORDER BY event_kind
SETTINGS optimize_aggregation_in_order = 1;

-- 각 대표 이벤트는 서로 다른 고객 그룹 두 개에 속한다.
SELECT
    count() AS actual_groups,
    sum(exact_count) AS actual_memberships,
    36 AS expected_groups,
    221000 AS expected_memberships,
    actual_groups = expected_groups
        AND actual_memberships = expected_memberships AS passed
FROM
(
    SELECT
        mall_id,
        store_id,
        customer_group_id,
        event_kind,
        sum(exact_count) AS exact_count
    FROM shop_a3.customer_group_counts
    WHERE product_id = 1000000
    GROUP BY mall_id, store_id, customer_group_id, event_kind
)
SETTINGS optimize_aggregation_in_order = 1;
