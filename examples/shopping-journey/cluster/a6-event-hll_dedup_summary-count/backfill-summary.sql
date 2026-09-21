-- dedup 상태가 있는 각 shard의 대표 replica에서 실행한다.

INSERT INTO shop_a6.event_summary_local
SELECT
    representative.1 AS mall_id,
    representative.2 AS store_id,
    product_id,
    toStartOfHour(representative.4) AS hour_start,
    event_kind,
    count() AS event_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a6.first_event_states_local
    GROUP BY product_id, journey_id, event_kind
)
GROUP BY mall_id, store_id, product_id, hour_start, event_kind
SETTINGS
    max_memory_usage = 2000000000,
    max_bytes_before_external_group_by = 50000000;

INSERT INTO shop_a6.customer_group_summary_local
SELECT
    representative.1 AS mall_id,
    representative.2 AS store_id,
    product_id,
    toStartOfHour(representative.4) AS hour_start,
    customer_group_id,
    event_kind,
    count() AS event_count
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a6.first_event_states_local
    GROUP BY product_id, journey_id, event_kind
)
ARRAY JOIN arrayDistinct(representative.3) AS customer_group_id
GROUP BY
    mall_id,
    store_id,
    product_id,
    hour_start,
    customer_group_id,
    event_kind
SETTINGS
    max_memory_usage = 2000000000,
    max_bytes_before_external_group_by = 50000000;
