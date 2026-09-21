#!/bin/sh
set -eu

LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}

benchmark() {
  label=$1
  iterations=$2
  query=$3

  echo "[$label] $iterations iterations, concurrency 1"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
    clickhouse-benchmark -i "$iterations" -c 1 --cumulative --query "$query"
}

benchmark "HLL normal product" 105 \
  "SELECT event_kind, uniqHLL12(journey_id) FROM shop_benchmark.shopping_events WHERE product_id = 1000000 GROUP BY event_kind FORMAT Null"

benchmark "HLL hot product" 105 \
  "SELECT event_kind, uniqHLL12(journey_id) FROM shop_benchmark.shopping_events WHERE product_id = 2000000 GROUP BY event_kind FORMAT Null"

benchmark "HLL all products" 30 \
  "SELECT event_kind, uniqHLL12(journey_id) FROM shop_benchmark.shopping_events GROUP BY event_kind FORMAT Null"

benchmark "exact summary normal product" 105 \
  "SELECT hour_start, event_kind, sum(event_count) FROM shop_a6.event_summary WHERE product_id = 1000000 GROUP BY hour_start, event_kind FORMAT Null"

benchmark "exact summary hot product" 105 \
  "SELECT hour_start, event_kind, sum(event_count) FROM shop_a6.event_summary WHERE product_id = 2000000 GROUP BY hour_start, event_kind FORMAT Null"

benchmark "exact group summary hot product" 105 \
  "SELECT hour_start, customer_group_id, event_kind, sum(event_count) FROM shop_a6.customer_group_summary WHERE product_id = 2000000 GROUP BY hour_start, customer_group_id, event_kind FORMAT Null"
