-- run-generate-data.sh가 100만 journey 단위로 실행한다.
--
--   journey_offset: 전체 1천만 범위에서 이번 chunk의 시작 번호
--   journey_count:  이번 chunk의 journey 수
--   hot_product:    일반 상품 0, 집중 상품 1

INSERT INTO shop_benchmark.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
SELECT
    concat(
        if({hot_product:UInt8} = 1, 'perf-hot-', 'perf-normal-'),
        toString(number), '-', lowerUTF8(event_kind), '-1'
    ) AS message_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(99),
        toUInt64(1 + intDiv(number, 100000) % 5)
    ) AS mall_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(999),
        toUInt64(100 + intDiv(number, 100000))
    ) AS store_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(2000000),
        toUInt64(1000000 + intDiv(number, 100000))
    ) AS product_id,
    concat(
        if({hot_product:UInt8} = 1, 'perf-hot-journey-', 'perf-normal-journey-'),
        toString(number)
    ) AS journey_id,
    [toUInt64(1 + number % 20), toUInt64(101 + number % 5)] AS customer_group_ids,
    event_kind,
    multiIf(event_kind = 'NOTIFY', 'notification', event_kind = 'CLICK', 'link', 'web') AS source_kind,
    toDateTime64('2026-03-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(number % 2419200) AS occurred_at,
    occurred_at + toIntervalSecond(1) AS received_at
FROM numbers({journey_offset:UInt64}, {journey_count:UInt64})
ARRAY JOIN ['NOTIFY', 'CLICK', 'VIEW', 'CART', 'PURCHASE'] AS event_kind
WHERE event_kind = 'NOTIFY'
   OR (event_kind = 'CLICK' AND number % 20 = 0)
   OR (event_kind = 'VIEW' AND number % 25 = 0)
   OR (event_kind = 'CART' AND number % 100 = 0)
   OR (event_kind = 'PURCHASE' AND number % 200 = 0);

-- PURCHASE가 있는 journey에는 늦게 수집된 CLICK 중복을 한 건 더 만든다.
INSERT INTO shop_benchmark.shopping_events
    (message_id, mall_id, store_id, product_id, journey_id,
     customer_group_ids, event_kind, source_kind, occurred_at, received_at)
SELECT
    concat(
        if({hot_product:UInt8} = 1, 'perf-hot-', 'perf-normal-'),
        toString(number), '-click-retry'
    ) AS message_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(99),
        toUInt64(1 + intDiv(number, 100000) % 5)
    ) AS mall_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(999),
        toUInt64(100 + intDiv(number, 100000))
    ) AS store_id,
    if(
        {hot_product:UInt8} = 1,
        toUInt64(2000000),
        toUInt64(1000000 + intDiv(number, 100000))
    ) AS product_id,
    concat(
        if({hot_product:UInt8} = 1, 'perf-hot-journey-', 'perf-normal-journey-'),
        toString(number)
    ) AS journey_id,
    [toUInt64(1 + number % 20), toUInt64(101 + number % 5)] AS customer_group_ids,
    'CLICK' AS event_kind,
    'link' AS source_kind,
    toDateTime64('2026-03-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(number % 2419200) - toIntervalSecond(60) AS occurred_at,
    occurred_at + toIntervalSecond(3601) AS received_at
FROM numbers({journey_offset:UInt64}, {journey_count:UInt64})
WHERE number % 200 = 0;
