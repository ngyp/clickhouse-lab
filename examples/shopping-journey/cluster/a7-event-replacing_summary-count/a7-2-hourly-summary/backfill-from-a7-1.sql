-- shard별 대표 replica에서 한 번씩 실행한다.
-- A7-1의 이벤트별 FINAL 결과와 동일한 최초 발생 상태를 A7-2에 적재한다.

INSERT INTO shop_a7_2.first_event_state_local
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
SELECT 'NOTIFY', mall_id, store_id, product_id, journey_id,
       customer_group_ids, occurred_at
FROM shop_a7_1.notification_events_local FINAL;

INSERT INTO shop_a7_2.first_event_state_local
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
SELECT 'VIEW', mall_id, store_id, product_id, journey_id,
       customer_group_ids, occurred_at
FROM shop_a7_1.view_events_local FINAL;

INSERT INTO shop_a7_2.first_event_state_local
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
SELECT 'CART', mall_id, store_id, product_id, journey_id,
       customer_group_ids, occurred_at
FROM shop_a7_1.cart_events_local FINAL;

INSERT INTO shop_a7_2.first_event_state_local
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
SELECT 'CLICK', mall_id, store_id, product_id, journey_id,
       customer_group_ids, occurred_at
FROM shop_a7_1.click_events_local FINAL;

INSERT INTO shop_a7_2.first_event_state_local
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
SELECT 'PURCHASE', mall_id, store_id, product_id, journey_id,
       customer_group_ids, occurred_at
FROM shop_a7_1.purchase_events_local FINAL;

-- 최초 snapshot은 +1/-1 이력이 없으므로 최초 상태를 바로 시간별 양수 count로 축약한다.
INSERT INTO shop_a7_2.hourly_summary_local
SELECT
    mall_id,
    store_id,
    product_id,
    toStartOfHour(first_occurred_at) AS event_hour,
    toInt64(countIf(event_type = 'NOTIFY')) AS notify_count,
    toInt64(countIf(event_type = 'VIEW')) AS view_count,
    toInt64(countIf(event_type = 'CART')) AS cart_count,
    toInt64(countIf(event_type = 'CLICK')) AS click_count,
    toInt64(countIf(event_type = 'PURCHASE')) AS purchase_count
FROM shop_a7_2.first_event_state_local FINAL
GROUP BY mall_id, store_id, product_id, event_hour;
