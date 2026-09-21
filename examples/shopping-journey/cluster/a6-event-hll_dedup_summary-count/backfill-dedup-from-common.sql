-- 각 shard의 대표 replica에서 실행한다.

INSERT INTO shop_a6.first_event_states_local
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
WHERE intHash64(cityHash64(journey_id)) % {bucket_count:UInt64} = {bucket:UInt64}
GROUP BY product_id, journey_id, event_kind
SETTINGS optimize_aggregation_in_order = 1;
