#!/bin/sh
set -eu

LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
FAILURE_POD=${FAILURE_POD:-chi-chi-cluster1-0-2-0}
ITERATIONS=${ITERATIONS:-2000}
CONCURRENCY=${CONCURRENCY:-4}

result_file=$(mktemp "${TMPDIR:-/tmp}/a6-failure.XXXXXX")
trap 'rm -f "$result_file"' EXIT

started_at=$(date +%s)
kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  delete pod "$FAILURE_POD"

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-benchmark -i "$ITERATIONS" -c "$CONCURRENCY" --cumulative --query "
    SELECT
      (SELECT uniqHLL12(journey_id)
       FROM shop_benchmark.shopping_events
       WHERE product_id = 2000000 AND event_kind = 'CLICK') AS hll_count,
      (SELECT sum(event_count)
       FROM shop_a6.event_summary
       WHERE product_id = 2000000 AND event_kind = 'CLICK') AS summary_count
    FORMAT Null" > "$result_file" 2>&1 &
benchmark_pid=$!

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  wait --for=condition=Ready "pod/$FAILURE_POD" --timeout=180s
ready_seconds=$(($(date +%s) - started_at))

wait "$benchmark_pid"
cat "$result_file"
echo "Pod delete request -> Ready: ${ready_seconds}s"

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --format PrettyCompact -q "
    SELECT
      sum(queue_size) AS replication_queue,
      max(absolute_delay) AS max_replication_delay,
      min(active_replicas) AS min_active_replicas
    FROM clusterAllReplicas('cluster1', system.replicas)
    WHERE database IN ('shop_benchmark', 'shop_a6');

    SELECT
      uniqHLL12(journey_id) AS hll_count,
      492597 AS expected_hll_count,
      hll_count = expected_hll_count AS hll_unchanged
    FROM shop_benchmark.shopping_events
    WHERE product_id = 2000000 AND event_kind = 'CLICK';

    SELECT
      sum(event_count) AS summary_count,
      500000 AS expected_summary_count,
      summary_count = expected_summary_count AS summary_unchanged
    FROM shop_a6.event_summary
    WHERE product_id = 2000000 AND event_kind = 'CLICK';"
