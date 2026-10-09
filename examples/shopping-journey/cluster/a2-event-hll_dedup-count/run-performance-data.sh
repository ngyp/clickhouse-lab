#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
LAB_MAX_MEMORY_USAGE=${LAB_MAX_MEMORY_USAGE:-2000000000}
CHUNK_SIZE=1000000
TOTAL_JOURNEYS_PER_CLASS=10000000

existing_rows=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q \
  "SELECT count() FROM shop_a2.shopping_events WHERE startsWith(journey_id, 'perf-')")

if [ "$existing_rows" -ne 0 ]; then
  echo "성능 데이터가 이미 ${existing_rows}행 있습니다. 새 shop_a2 DB에서 실행하세요." >&2
  exit 1
fi

for hot_product in 0 1; do
  if [ "$hot_product" -eq 0 ]; then
    class_name=normal
  else
    class_name=hot
  fi

  journey_offset=0
  while [ "$journey_offset" -lt "$TOTAL_JOURNEYS_PER_CLASS" ]; do
    echo "[$class_name] journey ${journey_offset}..$((journey_offset + CHUNK_SIZE - 1))"

    kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
      exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
      clickhouse-client --multiquery \
      --max_memory_usage="$LAB_MAX_MEMORY_USAGE" \
      --param_journey_offset="$journey_offset" \
      --param_journey_count="$CHUNK_SIZE" \
      --param_hot_product="$hot_product" \
      < "$SCRIPT_DIR/generate-performance-data.sql"

    journey_offset=$((journey_offset + CHUNK_SIZE))
  done
done
