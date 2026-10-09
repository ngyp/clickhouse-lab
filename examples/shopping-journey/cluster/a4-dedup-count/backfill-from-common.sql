-- shard의 대표 replica에서 한 번씩 실행한다.
-- 공통 원본과 A4 상태가 journey_id 기준으로 같은 shard에 있으므로 로컬 backfill한다.

INSERT INTO shop_a4.first_event_states_local
    (product_id, journey_id, event_kind, first_event_state)
SELECT
    product_id,
    journey_id,
    event_kind,
    argMinState(
        tuple(
            mall_id,
            store_id,
            customer_group_ids,
            occurred_at,
            received_at,
            toString(source_kind),
            message_id
        ),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_benchmark.shopping_events_local
GROUP BY product_id, journey_id, event_kind
SETTINGS optimize_aggregation_in_order = 1;
