-- 한 키의 최초 시간이 11:20에서 09:10으로 이동할 때 누적값은 1로 유지되어야 한다.
-- 운영에서는 입력 처리기가 state 조회 결과로 아래 signed delta를 결정한다.

INSERT INTO shop_a7_2.first_event_state
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
VALUES
    ('CLICK', 999, 9999, 9000004, 'a7-2-hour-move-1', emptyArrayUInt64(),
     toDateTime64('2026-09-28 11:20:00', 3, 'UTC'));

INSERT INTO shop_a7_2.hourly_summary
    (mall_id, store_id, product_id, event_hour,
     notify_count, view_count, cart_count, click_count, purchase_count)
VALUES
    (999, 9999, 9000004, toDateTime('2026-09-28 11:00:00', 'UTC'),
     0, 0, 0, 1, 0);

-- 12:30 후보는 11:20보다 늦으므로 state와 Summary 모두 기록하지 않는다.

-- 09:10 후보는 더 이르므로 state를 교체하고 시간 귀속만 이동한다.
INSERT INTO shop_a7_2.first_event_state
    (event_type, mall_id, store_id, product_id, journey_id,
     customer_group_ids, first_occurred_at)
VALUES
    ('CLICK', 999, 9999, 9000004, 'a7-2-hour-move-1', emptyArrayUInt64(),
     toDateTime64('2026-09-28 09:10:00', 3, 'UTC'));

INSERT INTO shop_a7_2.hourly_summary
    (mall_id, store_id, product_id, event_hour,
     notify_count, view_count, cart_count, click_count, purchase_count)
VALUES
    (999, 9999, 9000004, toDateTime('2026-09-28 11:00:00', 'UTC'),
     0, 0, 0, -1, 0),
    (999, 9999, 9000004, toDateTime('2026-09-28 09:00:00', 'UTC'),
     0, 0, 0, 1, 0);

SELECT
    first_occurred_at,
    first_occurred_at = toDateTime64('2026-09-28 09:10:00', 3, 'UTC') AS passed
FROM shop_a7_2.first_event_state FINAL
WHERE product_id = 9000004
  AND event_type = 'CLICK'
  AND journey_id = 'a7-2-hour-move-1';

SELECT
    event_hour,
    sum(click_count) AS click_count
FROM shop_a7_2.hourly_summary
WHERE product_id = 9000004
GROUP BY event_hour
HAVING click_count != 0
ORDER BY event_hour;

SELECT
    sum(click_count) AS total_click_count,
    total_click_count = 1 AS passed
FROM shop_a7_2.hourly_summary
WHERE product_id = 9000004;
