-- 비교안 B: 현재 INSERT block의 후보 키로 전체 이력을 먼저 제한한다.
-- cart-delta-full-history-join.sql의 MV와 동시에 활성화하지 않는다.

CREATE MATERIALIZED VIEW shop_a7_direct.cart_delta_candidate_filter_mv
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
history_for_candidates AS
(
    -- 전체 이력 중 이번 INSERT와 같은 키만 읽는다.
    -- 이벤트 테이블의 ORDER BY 선두가 (product_id, journey_id)여야 효과가 있다.
    SELECT *
    FROM shop_a7_direct.cart_events_history_local
    WHERE (product_id, journey_id) IN
    (
        SELECT product_id, journey_id
        FROM candidates
    )
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
    LEFT JOIN history_for_candidates AS h
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
