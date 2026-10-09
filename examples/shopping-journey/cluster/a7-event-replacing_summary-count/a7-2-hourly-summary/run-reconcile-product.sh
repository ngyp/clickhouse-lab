#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-clickhouse-0}

if [ "$#" -eq 0 ]; then
  echo "사용법: $0 product_id [product_id ...]" >&2
  exit 1
fi

# 보정끼리 같은 product를 동시에 처리하지 않도록 이 스크립트는 한 실행자에서 순차 수행한다.
for product_id in "$@"; do
  echo "[product_id=$product_id] A7-1 FINAL ↔ A7-2 hourly summary reconcile"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
    clickhouse-client --multiquery --param_product_id="$product_id" \
    < "$SCRIPT_DIR/reconcile-product.sql"
done
