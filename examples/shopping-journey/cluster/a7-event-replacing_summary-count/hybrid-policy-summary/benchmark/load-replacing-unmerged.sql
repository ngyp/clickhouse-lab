-- 교체 후보가 아직 background merge되지 않은 최악 조건을 재현한다.
SET optimize_on_insert = 0;

INSERT INTO shop_a7_hybrid_bench.replacing_raw
SELECT
    number AS ingest_row_id,
    toUInt64(1) AS product_id,
    concat('journey-', toString(intDiv(number, 10))) AS journey_id,
    toDateTime64('2026-10-01 00:00:00', 3, 'UTC')
        + toIntervalMinute(toUInt32(number % 10)) AS occurred_at,
    toDateTime64('2026-10-01 00:00:00', 3, 'UTC')
        + toIntervalSecond(toUInt32(number % 10)) AS received_at
FROM numbers_mt({rows:UInt64});
