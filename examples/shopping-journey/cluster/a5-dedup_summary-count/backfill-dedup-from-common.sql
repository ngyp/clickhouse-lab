-- 각 shard의 대표 replica에서 실행한다.
-- 원본과 dedup이 모두 journey_id로 분산되므로 키가 shard를 넘지 않는다.

INSERT INTO shop_a5.first_event_states_local
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
