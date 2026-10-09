-- generate-large-data.sql 직후 실행한다. journey_count는 같은 값을 전달한다.
-- 샘플 6행을 먼저 넣었다면 실제 raw/representative에는 각각 6/5를 더한다.

SELECT
    {journey_count:UInt64} AS journey_count,
    intDiv(journey_count * 111, 100) AS expected_generated_raw_rows,
    intDiv(journey_count * 1105, 1000) AS expected_generated_representative_rows,
    (SELECT count() FROM shop_a2.shopping_events WHERE startsWith(journey_id, 'load-')) AS actual_generated_raw_rows,
    (SELECT count() FROM shop_a2.first_events WHERE startsWith(journey_id, 'load-')) AS actual_generated_representative_rows
FORMAT Vertical;

SELECT
    exact.event_kind,
    exact.exact_journeys,
    approximate.hll_journeys,
    round(
        abs(toFloat64(approximate.hll_journeys) - toFloat64(exact.exact_journeys))
            / exact.exact_journeys * 100,
        3
    ) AS relative_error_percent
FROM
(
    SELECT event_kind, count() AS exact_journeys
    FROM shop_a2.first_events
    WHERE startsWith(journey_id, 'load-')
    GROUP BY event_kind
) AS exact
INNER JOIN
(
    SELECT event_kind, uniqHLL12(journey_id) AS hll_journeys
    FROM shop_a2.shopping_events
    WHERE startsWith(journey_id, 'load-')
    GROUP BY event_kind
) AS approximate USING (event_kind)
ORDER BY event_kind;
