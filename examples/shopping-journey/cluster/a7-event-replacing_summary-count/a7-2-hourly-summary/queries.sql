-- 예:
-- clickhouse-client \
--   --param_product_id=2000000 \
--   --param_from_hour='2026-03-01 00:00:00' \
--   --param_to_hour='2026-04-01 00:00:00' \
--   --multiquery < queries.sql

-- 서비스 조회 경로: 시간 Summary 숫자 행만 합산한다.
SELECT
    mall_id,
    store_id,
    product_id,
    event_hour,
    notify_count,
    view_count,
    cart_count,
    click_count,
    purchase_count
FROM shop_a7_2.hourly_summary_by_product(
    product_id = {product_id:UInt64},
    from_hour = {from_hour:DateTime},
    to_hour = {to_hour:DateTime}
)
ORDER BY event_hour;

-- 입력 판별 경로: 정확한 이벤트 키 하나의 현재 최초 시간을 확인한다.
SELECT first_occurred_at
FROM shop_a7_2.first_event_state FINAL
WHERE product_id = {product_id:UInt64}
  AND event_type = {event_type:String}
  AND journey_id = {journey_id:String}
SETTINGS optimize_skip_unused_shards = 1;
