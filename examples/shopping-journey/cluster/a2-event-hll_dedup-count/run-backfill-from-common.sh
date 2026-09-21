#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-clickhouse-0}

existing_states=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q "SELECT count() FROM shop_a2.first_event_states")

if [ "$existing_states" -ne 0 ]; then
  echo "A2 dedup state가 이미 ${existing_states}행 있습니다. 빈 shop_a2 DB에서 실행하세요." >&2
  exit 1
fi

# shard 1, 2, 3의 대표 replica다. 로컬 INSERT 결과는 같은 shard의 replica로 복제된다.
for pod in clickhouse-0 clickhouse-3 clickhouse-6; do
  echo "[$pod] common event -> A2 dedup backfill"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    < "$SCRIPT_DIR/backfill-from-common.sql"
done
