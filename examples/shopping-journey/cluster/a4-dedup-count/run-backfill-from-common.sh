#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_MAX_MEMORY_USAGE=${LAB_MAX_MEMORY_USAGE:-4000000000}
LAB_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY=${LAB_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY:-536870912}

if [ "$#" -gt 0 ]; then
  representative_pods="$*"
else
  representative_pods=${LAB_BACKFILL_PODS:-"chi-chi-cluster1-0-0-0 chi-chi-cluster1-1-0-0 chi-chi-cluster1-2-0-0 chi-chi-cluster1-3-0-0"}
fi

set -- $representative_pods
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-$1}

existing_states=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q "SELECT count() FROM shop_a4.first_event_states")

if [ "$existing_states" -ne 0 ]; then
  echo "A4 dedup state가 이미 ${existing_states}행 있습니다. 빈 shop_a4 DB에서 실행하세요." >&2
  exit 1
fi

# 각 shard의 대표 replica 한 곳에서 실행한다. 로컬 INSERT 결과는 같은 shard의 replica로 복제된다.
for pod in $representative_pods; do
  echo "[$pod] common event -> A4 dedup backfill"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    --max_memory_usage="$LAB_MAX_MEMORY_USAGE" \
    --max_bytes_before_external_group_by="$LAB_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY" \
    < "$SCRIPT_DIR/backfill-from-common.sql"
done
