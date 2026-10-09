-- A4: dedup 상태에서 누적·시간·고객 그룹별 exact count
-- 공통 event 원본은 재사용하고 A4에는 최초 이벤트 aggregate state만 저장한다.

CREATE DATABASE IF NOT EXISTS shop_a4 ON CLUSTER 'cluster1';

CREATE TABLE IF NOT EXISTS shop_a4.first_event_states_local ON CLUSTER 'cluster1'
(
    product_id UInt64,
    journey_id String,
    event_kind LowCardinality(String),
    first_event_state AggregateFunction(
        argMin,
        Tuple(
            UInt64,
            UInt64,
            Array(UInt64),
            DateTime64(3, 'UTC'),
            DateTime64(3, 'UTC'),
            String,
            String
        ),
        Tuple(DateTime64(3, 'UTC'), String)
    )
)
ENGINE = ReplicatedAggregatingMergeTree(
    '/clickhouse/tables/{shard}/shop_a4/first_event_states_local',
    '{replica}'
)
ORDER BY (product_id, journey_id, event_kind);

CREATE TABLE IF NOT EXISTS shop_a4.first_event_states ON CLUSTER 'cluster1'
AS shop_a4.first_event_states_local
ENGINE = Distributed(
    'cluster1',
    'shop_a4',
    'first_event_states_local',
    cityHash64(journey_id)
);

-- 공통 원본에 새로 입력되는 블록을 A4 dedup 상태로 반영한다.
-- 공통 snapshot의 기존 행은 별도 backfill 스크립트로 처리한다.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_a4.first_event_mv ON CLUSTER 'cluster1'
TO shop_a4.first_event_states_local
AS
SELECT
    product_id,
    journey_id,
    event_kind,
    argMinState(
        tuple(
            mall_id,
            store_id,
            customer_group_ids,
            occurred_at,
            received_at,
            toString(source_kind),
            message_id
        ),
        tuple(received_at, message_id)
    ) AS first_event_state
FROM shop_benchmark.shopping_events_local
GROUP BY product_id, journey_id, event_kind;

-- 전체 정합성 검사용 View다. 상품 단위 서비스 조회에는 아래 parameterized View를 사용한다.
CREATE VIEW IF NOT EXISTS shop_a4.first_events ON CLUSTER 'cluster1' AS
SELECT
    journey_id,
    event_kind,
    product_id,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    representative.3 AS customer_group_ids,
    representative.4 AS occurred_at,
    representative.5 AS received_at,
    representative.6 AS source_kind,
    representative.7 AS message_id
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a4.first_event_states
    GROUP BY product_id, journey_id, event_kind
);

-- product_id 조건을 aggregate state 병합 안쪽에 둬 관련 mark만 읽는다.
CREATE VIEW IF NOT EXISTS shop_a4.first_events_by_product ON CLUSTER 'cluster1' AS
SELECT
    journey_id,
    event_kind,
    product_id,
    representative.1 AS mall_id,
    representative.2 AS store_id,
    representative.3 AS customer_group_ids,
    representative.4 AS occurred_at,
    representative.5 AS received_at,
    representative.6 AS source_kind,
    representative.7 AS message_id
FROM
(
    SELECT
        product_id,
        journey_id,
        event_kind,
        argMinMerge(first_event_state) AS representative
    FROM shop_a4.first_event_states
    WHERE product_id = {product_id:UInt64}
    GROUP BY product_id, journey_id, event_kind
);
