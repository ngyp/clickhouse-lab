SELECT 'direct' AS method, count() AS logical_count
FROM shop_a7_hybrid_bench.direct_first
WHERE product_id = 1
UNION ALL
SELECT 'replacing' AS method, count() AS logical_count
FROM shop_a7_hybrid_bench.replacing_first FINAL
WHERE product_id = 1
UNION ALL
SELECT 'delta' AS method, sum(count_delta) AS logical_count
FROM shop_a7_hybrid_bench.delta_log
WHERE product_id = 1;

SELECT
    table,
    sum(rows) AS physical_rows,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size
FROM system.parts
WHERE active
  AND database = 'shop_a7_hybrid_bench'
  AND table IN ('direct_first', 'replacing_first', 'delta_log')
GROUP BY table
ORDER BY table;
