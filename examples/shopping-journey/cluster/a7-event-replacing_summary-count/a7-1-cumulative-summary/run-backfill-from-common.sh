#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_MAX_MEMORY_USAGE=${LAB_MAX_MEMORY_USAGE:-2000000000}

if [ "$#" -gt 0 ]; then
  representative_pods="$*"
else
  representative_pods=${LAB_BACKFILL_PODS:-"chi-chi-cluster1-0-0-0 chi-chi-cluster1-1-0-0 chi-chi-cluster1-2-0-0 chi-chi-cluster1-3-0-0"}
fi

set -- $representative_pods
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-$1}

existing_rows=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q "
    SELECT
        (SELECT count() FROM shop_a7_1.view_events)
      + (SELECT count() FROM shop_a7_1.cart_events)
      + (SELECT count() FROM shop_a7_1.click_events)
      + (SELECT count() FROM shop_a7_1.purchase_events)
      + (SELECT count() FROM shop_a7_1.notification_events)")

if [ "$existing_rows" -ne 0 ]; then
  echo "A7-1 이벤트 테이블에 이미 ${existing_rows}행 있습니다. 빈 shop_a7_1 DB에서 실행하세요." >&2
  exit 1
fi

# shard별 대표 replica에서 순차 실행한다. 이벤트 INSERT와 summary MV가 같은 요청에서 완료된다.
for pod in $representative_pods; do
  echo "[$pod] common event -> A7-1 event tables + cumulative summary"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    --max_memory_usage="$LAB_MAX_MEMORY_USAGE" \
    < "$SCRIPT_DIR/backfill-from-common.sql"
done
