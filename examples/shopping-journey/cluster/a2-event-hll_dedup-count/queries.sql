-- 1. Distributed 테이블의 논리 행 수와 dedup 대표 이벤트 수
SELECT count() AS raw_rows FROM shop_a2.shopping_events;
SELECT count() AS representative_rows FROM shop_a2.first_events;

-- 2. A2 전체 누적 경로: event에서 HLL
SELECT event_kind, uniqHLL12(journey_id) AS approximate_journeys
FROM shop_a2.shopping_events
WHERE product_id = 101
GROUP BY event_kind
ORDER BY event_kind;

-- 3. A2 상세 경로: dedup 상태를 병합한 뒤 시간별 직접 count
SELECT
    mall_id, store_id, product_id,
    toStartOfHour(occurred_at) AS hour_start,
    countIf(event_kind = 'NOTIFY') AS notify_count,
    countIf(event_kind = 'CLICK') AS click_count,
    countIf(event_kind = 'VIEW') AS view_count,
    countIf(event_kind = 'CART') AS cart_count,
    countIf(event_kind = 'PURCHASE') AS purchase_count
FROM shop_a2.first_events_by_product(product_id = 101)
WHERE occurred_at >= toDateTime64('2026-01-01 00:00:00', 3, 'UTC')
  AND occurred_at < toDateTime64('2026-01-02 00:00:00', 3, 'UTC')
GROUP BY mall_id, store_id, product_id, hour_start
ORDER BY hour_start;

-- 4. 고객 그룹별 직접 count
SELECT
    mall_id, store_id, customer_group_id,
    countIf(event_kind = 'NOTIFY') AS notify_count,
    countIf(event_kind = 'CLICK') AS click_count,
    countIf(event_kind = 'VIEW') AS view_count,
    countIf(event_kind = 'CART') AS cart_count,
    countIf(event_kind = 'PURCHASE') AS purchase_count
FROM shop_a2.first_events_by_product(product_id = 101)
ARRAY JOIN arrayDistinct(customer_group_ids) AS customer_group_id
WHERE mall_id = 1 AND store_id = 10
GROUP BY mall_id, store_id, customer_group_id
ORDER BY customer_group_id;

-- 5. shard 분산 확인. replica를 합산하지 않는 Distributed 결과다.
SELECT _shard_num AS shard_num, count() AS rows
FROM shop_a2.shopping_events
GROUP BY shard_num
ORDER BY shard_num;
