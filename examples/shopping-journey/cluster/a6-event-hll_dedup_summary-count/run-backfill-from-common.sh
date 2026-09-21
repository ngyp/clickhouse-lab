#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAB_KUBE_CONTEXT=${LAB_KUBE_CONTEXT:-kind-clickhouse-lab}
LAB_NAMESPACE=${LAB_NAMESPACE:-clickhouse}
LAB_CLICKHOUSE_POD=${LAB_CLICKHOUSE_POD:-chi-chi-cluster1-0-0-0}
DEDUP_BUCKETS=${DEDUP_BUCKETS:-8}

case "$DEDUP_BUCKETS" in
  ''|*[!0-9]*|0)
    echo "DEDUP_BUCKETS는 1 이상의 정수여야 합니다." >&2
    exit 1
    ;;
esac

existing_rows=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client -q "
    SELECT
      (SELECT count() FROM shop_a6.first_event_states) +
      (SELECT count() FROM shop_a6.event_summary) +
      (SELECT count() FROM shop_a6.customer_group_summary)")

if [ "$existing_rows" -ne 0 ]; then
  echo "A6 파생 테이블에 이미 ${existing_rows}행이 있습니다. 빈 shop_a6 DB에서 실행하세요." >&2
  exit 1
fi

representative_pods=$(kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
  exec "$LAB_CLICKHOUSE_POD" -c clickhouse -- \
  clickhouse-client --format TSVRaw -q \
  "SELECT hostName() FROM cluster('cluster1', system.one) ORDER BY _shard_num")

for pod in $representative_pods; do
  bucket=0
  while [ "$bucket" -lt "$DEDUP_BUCKETS" ]; do
    echo "[$pod] common event -> A6 dedup ($((bucket + 1))/$DEDUP_BUCKETS)"
    kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
      exec -i "$pod" -c clickhouse -- \
      clickhouse-client --multiquery \
      --param_bucket_count="$DEDUP_BUCKETS" \
      --param_bucket="$bucket" \
      < "$SCRIPT_DIR/backfill-dedup-from-common.sql"
    bucket=$((bucket + 1))
  done
done

for pod in $representative_pods; do
  echo "[$pod] A6 dedup -> summaries"
  kubectl --context "$LAB_KUBE_CONTEXT" -n "$LAB_NAMESPACE" \
    exec -i "$pod" -c clickhouse -- \
    clickhouse-client --multiquery \
    < "$SCRIPT_DIR/backfill-summary.sql"
done
