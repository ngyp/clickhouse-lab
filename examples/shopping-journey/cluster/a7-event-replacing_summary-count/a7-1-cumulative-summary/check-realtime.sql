-- 입력 처리기가 최초 키만 count_delta=1로 판정했다고 가정한다.
-- 같은 journey의 늦은 후보와 늦게 도착한 더 이른 후보는 count_delta=0으로 입력한다.

INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS insert_distributed_sync = 1
VALUES
    ('a7-live-initial', 900, 9000, 9000001, 'a7-live-journey-1', [901], 'link',
     toDateTime64('2026-09-28 10:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 10:00:01', 3, 'UTC'), 1);

INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS insert_distributed_sync = 1
VALUES
    ('a7-live-later', 900, 9000, 9000001, 'a7-live-journey-1', [901], 'link',
     toDateTime64('2026-09-28 11:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 11:00:01', 3, 'UTC'), 0);

INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS insert_distributed_sync = 1
VALUES
    ('a7-live-earlier', 900, 9000, 9000001, 'a7-live-journey-1', [901], 'link',
     toDateTime64('2026-09-28 09:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 12:00:00', 3, 'UTC'), 0);

SELECT sleep(1) FORMAT Null;

SELECT
    summary.click_count,
    (SELECT count()
     FROM shop_a7_1.click_events FINAL
     WHERE product_id = 9000001 AND journey_id = 'a7-live-journey-1') AS final_count,
    (SELECT any(message_id)
     FROM shop_a7_1.click_events FINAL
     WHERE product_id = 9000001 AND journey_id = 'a7-live-journey-1') AS winner_message_id,
    (SELECT any(occurred_at)
     FROM shop_a7_1.click_events FINAL
     WHERE product_id = 9000001 AND journey_id = 'a7-live-journey-1') AS winner_occurred_at,
    click_count = 1
        AND final_count = 1
        AND winner_message_id = 'a7-live-earlier'
        AND winner_occurred_at = toDateTime64('2026-09-28 09:00:00', 3, 'UTC') AS passed
FROM shop_a7_1.cumulative_summary_by_product(product_id = 9000001) AS summary;
