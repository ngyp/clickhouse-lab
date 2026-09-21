#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --multiquery \
  < "$SCRIPT_DIR/test-summary-latency-schema.sql"

echo "[raw] 1 row x 105"
kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-benchmark -i 105 -c 1 --cumulative --query "
    INSERT INTO shop_a5_latency_test.raw_events
    SELECT
      toString(generateUUIDv4()),
      toUInt64(1),
      toString(generateUUIDv4()),
      'CLICK',
      now64(3, 'UTC'),
      now64(3, 'UTC')"

echo "[chained MV] 1 row x 105"
kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-benchmark -i 105 -c 1 --cumulative --query "
    INSERT INTO shop_a5_latency_test.chain_events
    SELECT
      toString(generateUUIDv4()),
      toUInt64(1),
      toString(generateUUIDv4()),
      'CLICK',
      now64(3, 'UTC'),
      now64(3, 'UTC')"

echo "[chained MV] 1,000 rows x 30"
kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-benchmark -i 30 -c 1 --cumulative --query "
    INSERT INTO shop_a5_latency_test.chain_events
    SELECT
      concat(toString(generateUUIDv4()), '-', toString(number)),
      toUInt64(2),
      concat(toString(generateUUIDv4()), '-', toString(number)),
      'CLICK',
      now64(3, 'UTC'),
      now64(3, 'UTC')
    FROM numbers(1000)"

echo "[chained MV] 100,000 rows x 10"
kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-benchmark -i 10 -c 1 --cumulative --query "
    INSERT INTO shop_a5_latency_test.chain_events
    SELECT
      concat(toString(generateUUIDv4()), '-', toString(number)),
      toUInt64(3),
      concat(toString(generateUUIDv4()), '-', toString(number)),
      'CLICK',
      now64(3, 'UTC'),
      now64(3, 'UTC')
    FROM numbers(100000)"

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --multiquery --format PrettyCompact -q "
    INSERT INTO shop_a5_latency_test.chain_events VALUES
    ('visibility-message', 99, 'visibility-journey', 'CLICK',
     now64(3, 'UTC'), now64(3, 'UTC'));

    SELECT
      sum(event_count) AS visible_count,
      visible_count = 1 AS visible_immediately_after_insert
    FROM shop_a5_latency_test.naive_summary
    WHERE product_id = 99;

    DROP DATABASE shop_a5_latency_test;"
