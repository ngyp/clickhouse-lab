-- 같은 상품의 서로 다른 두 journey는 각각 한 번 집계되어 click_count=2가 되어야 한다.
-- 같은 journey의 중복 후보는 count_delta=0이므로 count를 증가시키지 않는다.

INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS
    insert_distributed_sync = 1,
    insert_deduplication_token = 'a7-count-delta-example-v1'
VALUES
    ('a7-delta-j1-first', 900, 9000, 9000003, 'a7-delta-journey-1',
     [901], 'link',
     toDateTime64('2026-09-28 10:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 10:00:01', 3, 'UTC'), 1),
    ('a7-delta-j1-duplicate', 900, 9000, 9000003, 'a7-delta-journey-1',
     [901], 'link',
     toDateTime64('2026-09-28 11:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 11:00:01', 3, 'UTC'), 0),
    ('a7-delta-j2-first', 900, 9000, 9000003, 'a7-delta-journey-2',
     [901], 'link',
     toDateTime64('2026-09-28 10:10:00', 3, 'UTC'),
     toDateTime64('2026-09-28 10:10:01', 3, 'UTC'), 1);

SELECT sleep(1) FORMAT Null;

SELECT
    summary.click_count,
    (SELECT sum(count_delta)
     FROM shop_a7_1.click_events
     WHERE product_id = 9000003) AS source_delta,
    (SELECT count()
     FROM shop_a7_1.click_events FINAL
     WHERE product_id = 9000003) AS final_journeys,
    click_count = 2
        AND source_delta = 2
        AND final_journeys = 2 AS passed
FROM shop_a7_1.cumulative_summary_by_product(product_id = 9000003) AS summary;
