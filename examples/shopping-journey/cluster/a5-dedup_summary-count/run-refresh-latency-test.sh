#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --multiquery \
  < "$SCRIPT_DIR/test-refresh-schema.sql" \
  > /dev/null

representative_pods=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --format TSVRaw -q \
  "SELECT hostName() FROM cluster('cluster1', system.one) ORDER BY _shard_num")

started_at=$(date +%s)
for pod in $representative_pods; do
  (
    kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
      exec -i "$pod" -c clickhouse -- \
      clickhouse-client --multiquery \
      < "$SCRIPT_DIR/test-refresh-backfill-local.sql"
  ) &
done
wait
finished_at=$(date +%s)

echo "refresh_wall_seconds=$((finished_at - started_at))"

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --format PrettyCompact -q "
    SELECT
      sum(event_count) AS actual_events,
      actual_events = 22100000 AS passed
    FROM cluster('cluster1', shop_a5_refresh_test.event_summary_local);

    SELECT
      sum(event_count) AS actual_group_memberships,
      actual_group_memberships = 44200000 AS passed
    FROM cluster('cluster1', shop_a5_refresh_test.customer_group_summary_local);

    SELECT
      sum(queue_size) AS replication_queue,
      max(absolute_delay) AS max_replication_delay
    FROM clusterAllReplicas('cluster1', system.replicas)
    WHERE database = 'shop_a5_refresh_test';"

kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q \
  "DROP DATABASE IF EXISTS shop_a5_refresh_test ON CLUSTER 'cluster1'" \
  > /dev/null
