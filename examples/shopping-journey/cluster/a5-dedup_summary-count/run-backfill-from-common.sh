#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}

existing_states=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q "SELECT count() FROM shop_a5.first_event_states")

if [ "$existing_states" -ne 0 ]; then
  echo "A5 dedup state가 이미 ${existing_states}행 있습니다. 빈 shop_a5 DB에서 실행하세요." >&2
  exit 1
fi

representative_pods=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --format TSVRaw -q \
  "SELECT hostName() FROM cluster('cluster1', system.one) ORDER BY _shard_num")

for pod in $representative_pods; do
  echo "[$pod] common event -> A5 dedup"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    < "$SCRIPT_DIR/backfill-dedup-from-common.sql"
done

for pod in $representative_pods; do
  echo "[$pod] A5 dedup -> summaries"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    < "$SCRIPT_DIR/backfill-summary.sql"
done
