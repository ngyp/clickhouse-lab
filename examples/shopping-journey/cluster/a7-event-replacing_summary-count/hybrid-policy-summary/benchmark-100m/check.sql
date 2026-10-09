SELECT
    (SELECT count() FROM shop_a7_hybrid_100m.event_history) AS raw_rows,
    (SELECT uniqExact(tracking_id) FROM shop_a7_hybrid_100m.event_history) AS tracking_ids,
    (SELECT min(c) FROM
        (SELECT count() AS c FROM shop_a7_hybrid_100m.event_history GROUP BY tracking_id)) AS min_rows_per_id,
    (SELECT max(c) FROM
        (SELECT count() AS c FROM shop_a7_hybrid_100m.event_history GROUP BY tracking_id)) AS max_rows_per_id,
    (SELECT count() FROM shop_a7_hybrid_100m.direct_first) AS direct_count,
    (SELECT count() FROM shop_a7_hybrid_100m.replacing_first FINAL) AS replacing_count,
    (SELECT sum(count_delta) FROM shop_a7_hybrid_100m.delta_log) AS delta_count;

SELECT
    table,
    sum(rows) AS physical_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE active
  AND database = 'shop_a7_hybrid_100m'
GROUP BY table
ORDER BY table;
