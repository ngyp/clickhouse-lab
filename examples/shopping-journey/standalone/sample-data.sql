-- schema/clickhouse.sql 적용 후 입력한다.
-- 실험의 입력 계약: 속성 보강이 완료된 구매 여정 이벤트를 shopping_events에 입력한다.
-- 새 빈 예제 DB에서 한 번 실행했을 때의 기대값을 README에 기술했다.
-- 재실행하면 원본과 recent 행은 추가된다. 자동 INSERT 중복 차단을 가정하지 않는다.
INSERT INTO shop_analytics.shopping_events
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

-- 별도 INSERT로 늦게 수집된 중복을 입력한다. 블록 간에도 최초 대표가 유지되어야 한다.
INSERT INTO shop_analytics.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
VALUES
    ('demo-03', 1, 10, 101, 'journey-a', [1], 'CLICK', 'link',
     '2026-01-01 09:30:00.000', '2026-01-01 11:00:00.000');
