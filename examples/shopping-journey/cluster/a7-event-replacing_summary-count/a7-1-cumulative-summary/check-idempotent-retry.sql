-- 동일한 메시지 재시도는 같은 insert_deduplication_token을 사용한다.
-- logical event key가 같지만 message_id가 다른 동시 입력은 이 token의 범위가 아니며,
-- README의 partition 단위 직렬화 계약으로 count_delta를 한 번만 판정해야 한다.

INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS
    insert_distributed_sync = 1,
    insert_deduplication_token = 'a7-retry-message-1'
VALUES
    ('a7-retry-message-1', 900, 9000, 9000002, 'a7-retry-journey-1',
     [901], 'link',
     toDateTime64('2026-09-28 10:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 10:00:01', 3, 'UTC'), 1);

-- 첫 번째 INSERT의 응답을 잃었다고 가정하고 같은 message와 token으로 재시도한다.
INSERT INTO shop_a7_1.click_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, source_kind, occurred_at, received_at, count_delta)
SETTINGS
    insert_distributed_sync = 1,
    insert_deduplication_token = 'a7-retry-message-1'
VALUES
    ('a7-retry-message-1', 900, 9000, 9000002, 'a7-retry-journey-1',
     [901], 'link',
     toDateTime64('2026-09-28 10:00:00', 3, 'UTC'),
     toDateTime64('2026-09-28 10:00:01', 3, 'UTC'), 1);

SELECT sleep(1) FORMAT Null;

SELECT
    summary.click_count,
    (SELECT count()
     FROM shop_a7_1.click_events
     WHERE product_id = 9000002 AND journey_id = 'a7-retry-journey-1') AS stored_rows,
    click_count = 1 AND stored_rows = 1 AS passed
FROM shop_a7_1.cumulative_summary_by_product(product_id = 9000002) AS summary;
