-- 한 INSERT block 내부 중복: VIEW는 received_at이 가장 빠른 한 행만 승인한다.
INSERT INTO shop_a7_hybrid.view_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'view-j-1', [1],
     toDateTime64('2026-10-01 10:05:00', 3, 'UTC'),
     toDateTime64('2026-10-01 10:05:01', 3, 'UTC')),
    (701, 7001, 700001, 'view-j-1', [1],
     toDateTime64('2026-10-01 09:05:00', 3, 'UTC'),
     toDateTime64('2026-10-01 10:05:02', 3, 'UTC'));

-- 다음 block에 더 이른 occurred_at이 와도 최초 입수 정책이므로 무시한다.
INSERT INTO shop_a7_hybrid.view_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'view-j-1', [1],
     toDateTime64('2026-10-01 08:05:00', 3, 'UTC'),
     toDateTime64('2026-10-01 11:00:00', 3, 'UTC'));

INSERT INTO shop_a7_hybrid.click_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'click-j-1', [1],
     toDateTime64('2026-10-01 10:30:00', 3, 'UTC'),
     toDateTime64('2026-10-01 10:30:01', 3, 'UTC'));

-- CART: 11:20 최초, 12:30 무시, 늦게 입수된 09:10이 11시를 취소하고 09시로 이동한다.
INSERT INTO shop_a7_hybrid.cart_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'cart-j-1', [1],
     toDateTime64('2026-10-01 11:20:00', 3, 'UTC'),
     toDateTime64('2026-10-01 11:20:01', 3, 'UTC'));

INSERT INTO shop_a7_hybrid.cart_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'cart-j-1', [1],
     toDateTime64('2026-10-01 12:30:00', 3, 'UTC'),
     toDateTime64('2026-10-01 12:30:01', 3, 'UTC'));

INSERT INTO shop_a7_hybrid.cart_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'cart-j-1', [1],
     toDateTime64('2026-10-01 09:10:00', 3, 'UTC'),
     toDateTime64('2026-10-01 13:00:00', 3, 'UTC'));

-- PURCHASE도 가장 빠른 발생 시각 정책을 사용한다.
INSERT INTO shop_a7_hybrid.purchase_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'purchase-j-1', [1],
     toDateTime64('2026-10-01 15:10:00', 3, 'UTC'),
     toDateTime64('2026-10-01 15:10:01', 3, 'UTC'));

INSERT INTO shop_a7_hybrid.purchase_events_local
    (mall_id, store_id, product_id, journey_id, customer_group_ids, occurred_at, received_at)
VALUES
    (701, 7001, 700001, 'purchase-j-1', [1],
     toDateTime64('2026-10-01 14:10:00', 3, 'UTC'),
     toDateTime64('2026-10-01 16:00:00', 3, 'UTC'));

SELECT sleep(1) FORMAT Null;

-- 최초 입수 고정 테이블은 각 키당 한 행이어야 한다.
SELECT
    (SELECT count() FROM shop_a7_hybrid.view_first_received_local
     WHERE product_id = 700001 AND journey_id = 'view-j-1') AS view_first_rows,
    (SELECT min(occurred_at) FROM shop_a7_hybrid.view_first_received_local
     WHERE product_id = 700001 AND journey_id = 'view-j-1') AS accepted_view_at,
    (SELECT count() FROM shop_a7_hybrid.click_first_received_local
     WHERE product_id = 700001 AND journey_id = 'click-j-1') AS click_first_rows,
    view_first_rows = 1
        AND accepted_view_at = toDateTime64('2026-10-01 10:05:00', 3, 'UTC')
        AND click_first_rows = 1 AS passed;

-- CART/PURCHASE delta 원장을 그대로 확인한다.
SELECT event_type, event_hour, sum(count_delta) AS net_count
FROM shop_a7_hybrid.event_summary_delta_local
WHERE product_id = 700001
GROUP BY event_type, event_hour
ORDER BY event_type, event_hour;

-- 통합 시간 결과: 09시 CART 1, 10시 VIEW 1/CLICK 1, 14시 PURCHASE 1.
SELECT *
FROM shop_a7_hybrid.hourly_summary_local_view
WHERE product_id = 700001
ORDER BY event_hour;

-- 서로 다른 내부 구현을 사용해도 누적 결과는 이벤트별 1이어야 한다.
SELECT
    *,
    view_count = 1
        AND cart_count = 1
        AND click_count = 1
        AND purchase_count = 1 AS passed
FROM shop_a7_hybrid.cumulative_summary_local_view
WHERE product_id = 700001;
