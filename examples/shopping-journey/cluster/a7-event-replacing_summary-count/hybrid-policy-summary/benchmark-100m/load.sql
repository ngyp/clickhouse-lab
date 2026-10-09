-- 100만 tracking ID × ID별 100행 = 원본 1억 행.
INSERT INTO shop_a7_hybrid_100m.event_history
SELECT
    number AS ingest_row_id,
    toUInt64(1) AS product_id,
    intDiv(number, 100) AS tracking_id,
    toDateTime64('2026-10-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(toUInt32(number % 100)) AS occurred_at,
    toDateTime64('2026-10-01 00:10:00', 3, 'UTC')
        + toIntervalSecond(toUInt32(number % 100)) AS received_at
FROM numbers_mt(100000000);

-- 최초 입수 고정 대표 100만 행.
INSERT INTO shop_a7_hybrid_100m.direct_first
SELECT
    toUInt64(1),
    number,
    toDateTime64('2026-10-01 00:00:00', 3, 'UTC'),
    toDateTime64('2026-10-01 00:10:00', 3, 'UTC')
FROM numbers_mt(1000000);

-- 현재 시간 귀속의 +1 100만 행.
INSERT INTO shop_a7_hybrid_100m.delta_log
SELECT
    toUInt64(1),
    toDateTime('2026-10-01 00:00:00', 'UTC'),
    toInt64(1)
FROM numbers_mt(1000000);

-- 작은 INSERT가 누적되어 아직 merge되지 않은 Replacing 최악 조건을 유지한다.
SYSTEM STOP MERGES shop_a7_hybrid_100m.replacing_first;
SET optimize_on_insert = 0;

INSERT INTO shop_a7_hybrid_100m.replacing_first
    (product_id, tracking_id, occurred_at, received_at)
SELECT
    product_id,
    tracking_id,
    occurred_at,
    received_at
FROM shop_a7_hybrid_100m.event_history;
