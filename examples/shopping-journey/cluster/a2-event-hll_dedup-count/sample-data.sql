-- Distributed 테이블에 넣어 journey_id 기준으로 shard를 선택한다.
INSERT INTO shop_a2.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
VALUES
    ('demo-01', 1, 10, 101, 'journey-a', [1], 'NOTIFY', 'notification',
     '2026-01-01 09:00:00.000', '2026-01-01 09:00:01.000'),
    ('demo-02', 1, 10, 101, 'journey-a', [1], 'CLICK', 'link',
     '2026-01-01 10:00:00.000', '2026-01-01 10:00:01.000'),
    ('demo-04', 1, 10, 101, 'journey-b', [1, 2], 'VIEW', 'web',
     '2026-01-01 10:05:00.000', '2026-01-01 10:05:01.000'),
    ('demo-05', 1, 10, 101, 'journey-b', [1, 2], 'CART', 'web',
     '2026-01-01 10:06:00.000', '2026-01-01 10:06:01.000'),
    ('demo-06', 1, 10, 101, 'journey-b', [1, 2], 'PURCHASE', 'web',
     '2026-01-01 10:07:00.000', '2026-01-01 10:07:01.000');

-- 발생 시각은 빠르지만 늦게 수집된 CLICK. 대표 이벤트는 demo-02여야 한다.
INSERT INTO shop_a2.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
VALUES
    ('demo-03', 1, 10, 101, 'journey-a', [1], 'CLICK', 'link',
     '2026-01-01 09:30:00.000', '2026-01-01 11:00:00.000');
