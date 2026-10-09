-- 비교안 A: candidates 한 건이어도 JOIN 오른쪽 전체 이력을 읽을 수 있다.
-- 성능 비교용이며 운영 후보로 사용하지 않는다.
-- cart-delta-candidate-filter.sql의 MV와 동시에 활성화하지 않는다.

CREATE MATERIALIZED VIEW shop_a7_direct.cart_delta_full_history_mv
TO shop_a7_direct.event_summary_delta_local AS
WITH
candidates AS
(
    -- 증분 MV에서 이 source는 현재 INSERT block이다.
    SELECT
        mall_id,
        store_id,
        product_id,
        journey_id,
        min(occurred_at) AS candidate_at,
        groupUniqArray(ingest_row_id) AS block_ingest_ids
    FROM shop_a7_direct.cart_events_local
    GROUP BY mall_id, store_id, product_id, journey_id
),
evaluated AS
(
    SELECT
        c.mall_id,
        c.store_id,
        c.product_id,
        c.journey_id,
        c.candidate_at,
        countIf(
            h.ingest_row_id != toUUID('00000000-0000-0000-0000-000000000000')
            AND NOT has(c.block_ingest_ids, h.ingest_row_id)
        ) AS history_count,
        minIf(
            toNullable(h.occurred_at),
            h.ingest_row_id != toUUID('00000000-0000-0000-0000-000000000000')
            AND NOT has(c.block_ingest_ids, h.ingest_row_id)
        ) AS previous_at
    FROM candidates AS c
    -- 후보가 한 건이어도 오른쪽 전체 이력을 먼저 읽어 Hash JOIN을 만들 수 있다.
    LEFT JOIN shop_a7_direct.cart_events_history_local AS h
        ON h.product_id = c.product_id
       AND h.journey_id = c.journey_id
    GROUP BY
        c.mall_id,
        c.store_id,
        c.product_id,
        c.journey_id,
        c.candidate_at,
        c.block_ingest_ids
)
SELECT
    mall_id,
    store_id,
    product_id,
    'CART' AS event_type,
    delta.1 AS event_hour,
    delta.2 AS count_delta
FROM evaluated
ARRAY JOIN
    multiIf(
        history_count = 0,
        [tuple(toDateTime(toStartOfHour(candidate_at), 'UTC'), toInt64(1))],
        candidate_at < previous_at,
        [
            tuple(toDateTime(toStartOfHour(previous_at), 'UTC'), toInt64(-1)),
            tuple(toDateTime(toStartOfHour(candidate_at), 'UTC'), toInt64(1))
        ],
        CAST([], 'Array(Tuple(DateTime(\'UTC\'), Int64))')
    ) AS delta;
