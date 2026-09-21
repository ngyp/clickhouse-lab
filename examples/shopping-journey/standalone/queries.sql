-- 1. 원본과 대표 이벤트 개수: 샘플 1회 입력 시 6 / 5
SELECT count() AS raw_rows FROM shop_analytics.shopping_events;
SELECT count() AS representative_rows FROM shop_analytics.first_events;

-- 2. 상품별 전체 누적 근사값: 최초 시각을 결정하는 조회가 아니다.
SELECT event_kind, uniqHLL12(journey_id) AS approximate_journeys
FROM shop_analytics.shopping_events
WHERE product_id = 101
GROUP BY event_kind
ORDER BY event_kind;

-- 3. A1의 RDS 상품 통계를 만들기 위한 배치 계산/검증 쿼리.
-- 최초 수집 이벤트의 발생 시각에 귀속한 시간별 정확 집계다.
-- 현재 구조는 대표 선택 기준(received_at)과 시간 귀속 기준(occurred_at)이 다르다.
-- 시간 귀속 기준은 이 조회 예제에서 명시적으로 선택한 것이며,
-- 기존 시스템의 배치 구현을 복원한 것이 아니다.
SELECT
    mall_id, store_id, product_id,
    toStartOfHour(occurred_at) AS hour_start,
    countIf(event_kind = 'NOTIFY') AS notify_count,
    countIf(event_kind = 'CLICK') AS click_count,
    countIf(event_kind = 'VIEW') AS view_count,
    countIf(event_kind = 'CART') AS cart_count,
    countIf(event_kind = 'PURCHASE') AS purchase_count
FROM shop_analytics.first_events
WHERE product_id = 101
  AND occurred_at >= toDateTime64('2026-01-01 00:00:00', 3, 'UTC')
  AND occurred_at < toDateTime64('2026-01-02 00:00:00', 3, 'UTC')
GROUP BY mall_id, store_id, product_id, hour_start
ORDER BY hour_start;

-- 4. A1의 RDS 고객 그룹 통계를 만들기 위한 배치 계산/검증 쿼리.
-- 중복 그룹 ID를 제거한 뒤 전개해 정확 집계한다.
-- RDS 그룹 키와 동일하게 매장 내 전체 상품·전체 기간을 대상으로 한다.
-- 빈 그룹 배열은 결과에서 제외하고, 여러 그룹이면 각각 집계한다.
SELECT
    mall_id, store_id, customer_group_id,
    countIf(event_kind = 'NOTIFY') AS notify_count,
    countIf(event_kind = 'CLICK') AS click_count,
    countIf(event_kind = 'VIEW') AS view_count,
    countIf(event_kind = 'CART') AS cart_count,
    countIf(event_kind = 'PURCHASE') AS purchase_count
FROM shop_analytics.first_events
ARRAY JOIN arrayDistinct(customer_group_ids) AS customer_group_id
WHERE mall_id = 1 AND store_id = 10
GROUP BY mall_id, store_id, customer_group_id
ORDER BY customer_group_id;
