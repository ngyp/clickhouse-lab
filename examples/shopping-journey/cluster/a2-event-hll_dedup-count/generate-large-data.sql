-- 실행 시 --param_journey_count=1000000 형태로 journey 수를 전달한다.
-- journey_count는 이벤트 비율 계산을 단순하게 하도록 200의 배수를 권장한다.
-- 100만 journey 기준: 대표 이벤트 1,105,000행, 중복 포함 원본 1,110,000행.

INSERT INTO shop_a2.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
SELECT
    concat('load-', toString(number), '-', lowerUTF8(event_kind), '-1') AS message_id,
    toUInt64(1 + number % 5) AS mall_id,
    toUInt64(100 + number % 100) AS store_id,
    toUInt64(1000 + number % 20000) AS product_id,
    concat('load-journey-', toString(number)) AS journey_id,
    [toUInt64(1 + number % 20), toUInt64(101 + number % 5)] AS customer_group_ids,
    event_kind,
    multiIf(event_kind = 'NOTIFY', 'notification', event_kind = 'CLICK', 'link', 'web') AS source_kind,
    toDateTime64('2026-02-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(number % 2419200) AS occurred_at,
    occurred_at + toIntervalSecond(1) AS received_at
FROM numbers({journey_count:UInt64})
ARRAY JOIN ['NOTIFY', 'CLICK', 'VIEW', 'CART', 'PURCHASE'] AS event_kind
WHERE event_kind = 'NOTIFY'
   OR (event_kind = 'CLICK' AND number % 20 = 0)
   OR (event_kind = 'VIEW' AND number % 25 = 0)
   OR (event_kind = 'CART' AND number % 100 = 0)
   OR (event_kind = 'PURCHASE' AND number % 200 = 0);

-- PURCHASE가 있는 journey에는 늦게 수집된 CLICK 중복을 한 건 더 만든다.
-- 발생 시각은 기존 CLICK보다 빠르지만 received_at이 늦어 대표가 바뀌지 않아야 한다.
INSERT INTO shop_a2.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
SELECT
    concat('load-', toString(number), '-click-retry') AS message_id,
    toUInt64(1 + number % 5) AS mall_id,
    toUInt64(100 + number % 100) AS store_id,
    toUInt64(1000 + number % 20000) AS product_id,
    concat('load-journey-', toString(number)) AS journey_id,
    [toUInt64(1 + number % 20), toUInt64(101 + number % 5)] AS customer_group_ids,
    'CLICK' AS event_kind,
    'link' AS source_kind,
    toDateTime64('2026-02-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(number % 2419200) - toIntervalSecond(60) AS occurred_at,
    occurred_at + toIntervalSecond(3601) AS received_at
FROM numbers({journey_count:UInt64})
WHERE number % 200 = 0;
