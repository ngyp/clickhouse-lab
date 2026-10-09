-- 각 shard의 대표 replica에서 한 번씩 실행한다.
-- 공통 원본과 A7-1 이벤트 테이블은 journey_id 기준으로 같은 shard에 배치된다.
-- 공통 데이터에서 CLICK만 중복을 가지므로 최초 수집 행 하나만 count_delta=1로 표시한다.

INSERT INTO shop_a7_1.view_events_local
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SELECT message_id, mall_id, store_id, product_id, journey_id,
       customer_group_ids, source_kind, occurred_at, received_at, toUInt8(1)
FROM shop_benchmark.shopping_events_local
WHERE event_kind = 'VIEW';

INSERT INTO shop_a7_1.cart_events_local
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SELECT message_id, mall_id, store_id, product_id, journey_id,
       customer_group_ids, source_kind, occurred_at, received_at, toUInt8(1)
FROM shop_benchmark.shopping_events_local
WHERE event_kind = 'CART';

INSERT INTO shop_a7_1.click_events_local
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SELECT
    message_id, mall_id, store_id, product_id, journey_id,
    customer_group_ids, source_kind, occurred_at, received_at,
    toUInt8(row_number() OVER (
        PARTITION BY product_id, journey_id
        ORDER BY received_at, message_id
    ) = 1) AS count_delta
FROM shop_benchmark.shopping_events_local
WHERE event_kind = 'CLICK';

INSERT INTO shop_a7_1.purchase_events_local
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SELECT message_id, mall_id, store_id, product_id, journey_id,
       customer_group_ids, source_kind, occurred_at, received_at, toUInt8(1)
FROM shop_benchmark.shopping_events_local
WHERE event_kind = 'PURCHASE';

INSERT INTO shop_a7_1.notification_events_local
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SELECT message_id, mall_id, store_id, product_id, journey_id,
       customer_group_ids, source_kind, occurred_at, received_at, toUInt8(1)
FROM shop_benchmark.shopping_events_local
WHERE event_kind = 'NOTIFY';
