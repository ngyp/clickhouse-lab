-- Push/Click 서비스 스키마
-- 적용 방법:
--   kubectl --context kind-clickhouse-lab -n clickhouse exec -i chi-chi-cluster1-0-0-0 \
--     -- clickhouse-client --multiquery < 001_init.sql
--
-- default DB의 실험용 events/events_local 테이블과 격리하기 위해 별도 DB(push_click)에 둔다.

CREATE DATABASE IF NOT EXISTS push_click ON CLUSTER 'cluster1';

-- =========================================================================
-- 1. customers (고객) — 저빈도 변경 마스터 데이터. ReplacingMergeTree로 upsert.
-- =========================================================================

CREATE TABLE IF NOT EXISTS push_click.customers_local ON CLUSTER 'cluster1'
(
    customer_id UInt64,
    device_token String,
    segment     LowCardinality(String) DEFAULT 'default',
    created_at  DateTime DEFAULT now(),
    updated_at  DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/push_click/customers_local', '{replica}', updated_at
)
ORDER BY customer_id;

CREATE TABLE IF NOT EXISTS push_click.customers ON CLUSTER 'cluster1' AS push_click.customers_local
ENGINE = Distributed('cluster1', 'push_click', customers_local, cityHash64(customer_id));

-- =========================================================================
-- 2. pushes (발송) — 앱 푸시 발송 이벤트. append-only 팩트 테이블.
-- =========================================================================

CREATE TABLE IF NOT EXISTS push_click.pushes_local ON CLUSTER 'cluster1'
(
    send_id     UUID,
    customer_id UInt64,
    campaign_id UInt64,
    template_id LowCardinality(String),
    sent_at     DateTime DEFAULT now(),
    status      LowCardinality(String) DEFAULT 'SENT'
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/push_click/pushes_local', '{replica}')
PARTITION BY toYYYYMMDD(sent_at)
ORDER BY (campaign_id, sent_at, send_id)
-- 원본 이벤트는 90일 후 만료. 사전집계(push_stats_local)는 훨씬 작고 리포팅
-- 가치가 오래 유지되므로 별도 TTL을 두지 않는다. TTL은 병합(또는
-- MATERIALIZE TTL)이 그 파트를 건드릴 때만 실제로 적용된다 — GUIDE.md 16절
-- 참고, "만료 즉시 삭제"가 아니다.
TTL sent_at + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS push_click.pushes ON CLUSTER 'cluster1' AS push_click.pushes_local
ENGINE = Distributed('cluster1', 'push_click', pushes_local, cityHash64(customer_id));

-- =========================================================================
-- 3. clicks (클릭) — 푸시 클릭 이벤트.
--    campaign_id를 클릭 이벤트에도 미리 태깅해서, 통계 집계 시 발송 테이블과의
--    실시간 JOIN 없이도 독립적으로 집계할 수 있게 한다 (아래 MV 설계 참고).
-- =========================================================================

CREATE TABLE IF NOT EXISTS push_click.clicks_local ON CLUSTER 'cluster1'
(
    click_id    UUID,
    send_id     UUID,
    customer_id UInt64,
    campaign_id UInt64,
    clicked_at  DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/push_click/clicks_local', '{replica}')
PARTITION BY toYYYYMMDD(clicked_at)
ORDER BY (campaign_id, clicked_at, click_id)
-- pushes_local과 동일한 90일 보존 정책.
TTL clicked_at + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS push_click.clicks ON CLUSTER 'cluster1' AS push_click.clicks_local
ENGINE = Distributed('cluster1', 'push_click', clicks_local, cityHash64(customer_id));

-- =========================================================================
-- 4. 실시간 통계: 발송/클릭을 각각 독립적으로 집계하는 두 개의 Materialized View.
--
--    주의: "발송 JOIN 클릭"을 하나의 MV로 만들지 않는다. ClickHouse의 MV는
--    한쪽 원본 테이블에 INSERT가 발생할 때만 트리거되는 "per-source-table"
--    트리거이므로, 클릭이 나중에 도착해도 발송 쪽 MV가 재계산되지 않아
--    결과가 틀어진다. 대신 두 스트림을 독립적으로 사전집계하고, 조회 시점에
--    가벼운 조인으로 합친다 (아래 campaign_realtime_stats).
-- =========================================================================

CREATE TABLE IF NOT EXISTS push_click.push_stats_local ON CLUSTER 'cluster1'
(
    campaign_id UInt64,
    hour        DateTime,
    sent_count  AggregateFunction(count)
)
ENGINE = ReplicatedAggregatingMergeTree('/clickhouse/tables/{shard}/push_click/push_stats_local', '{replica}')
ORDER BY (campaign_id, hour);

CREATE MATERIALIZED VIEW IF NOT EXISTS push_click.push_stats_mv ON CLUSTER 'cluster1'
TO push_click.push_stats_local
AS
SELECT
    campaign_id,
    toStartOfHour(sent_at) AS hour,
    countState()           AS sent_count
FROM push_click.pushes_local
GROUP BY campaign_id, hour;

CREATE TABLE IF NOT EXISTS push_click.click_stats_local ON CLUSTER 'cluster1'
(
    campaign_id      UInt64,
    hour             DateTime,
    click_count      AggregateFunction(count),
    unique_customers AggregateFunction(uniq, UInt64)
)
ENGINE = ReplicatedAggregatingMergeTree('/clickhouse/tables/{shard}/push_click/click_stats_local', '{replica}')
ORDER BY (campaign_id, hour);

CREATE MATERIALIZED VIEW IF NOT EXISTS push_click.click_stats_mv ON CLUSTER 'cluster1'
TO push_click.click_stats_local
AS
SELECT
    campaign_id,
    toStartOfHour(clicked_at) AS hour,
    countState()              AS click_count,
    uniqState(customer_id)    AS unique_customers
FROM push_click.clicks_local
GROUP BY campaign_id, hour;

CREATE TABLE IF NOT EXISTS push_click.push_stats ON CLUSTER 'cluster1' AS push_click.push_stats_local
ENGINE = Distributed('cluster1', 'push_click', push_stats_local, rand());

CREATE TABLE IF NOT EXISTS push_click.click_stats ON CLUSTER 'cluster1' AS push_click.click_stats_local
ENGINE = Distributed('cluster1', 'push_click', click_stats_local, rand());

-- =========================================================================
-- 5. 실시간 CTR 뷰 — 사전집계된 두 Distributed 테이블을 쿼리 시점에 조인.
--    (원본 이벤트가 아니라 campaign x hour 단위로 이미 작아진 데이터를 조인하므로
--    비용이 거의 들지 않는다.)
--
--    주의: Distributed 테이블끼리 그냥 JOIN하면 각 샤드가 오른쪽 테이블을 다시
--    분산 서브쿼리로 흩뿌리려다 "Double-distributed IN/JOIN subqueries is
--    denied (distributed_product_mode = 'deny')" 에러가 난다. GLOBAL JOIN을
--    쓰면 오른쪽 결과를 한 번만 계산해 각 샤드에 브로드캐스트하므로 이 문제가
--    없다 (두 결과 모두 campaign x hour 단위로 이미 작아서 브로드캐스트 비용도
--    낮다).
-- =========================================================================

CREATE VIEW IF NOT EXISTS push_click.campaign_realtime_stats ON CLUSTER 'cluster1' AS
SELECT
    p.campaign_id                                AS campaign_id,
    p.hour                                        AS hour,
    countMerge(p.sent_count)                      AS sent_count,
    countMerge(c.click_count)                     AS click_count,
    uniqMerge(c.unique_customers)                 AS unique_clickers,
    countMerge(c.click_count) / countMerge(p.sent_count) AS ctr
FROM push_click.push_stats AS p
GLOBAL LEFT JOIN push_click.click_stats AS c
    ON p.campaign_id = c.campaign_id AND p.hour = c.hour
GROUP BY p.campaign_id, p.hour;
