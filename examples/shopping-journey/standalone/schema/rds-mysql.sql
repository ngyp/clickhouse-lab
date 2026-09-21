-- 쇼핑몰 배치 통계: MySQL 8.0.16 이상 / 8.4용 예제 DDL (CHECK 제약 사용)
-- 새 빈 실습 DB용이다. 기존 PostgreSQL DB를 변환하는 마이그레이션이 아니다.
-- 식별자는 ClickHouse UInt64에 맞춰 BIGINT UNSIGNED를 사용한다.
-- 모든 배치 연결에서도 time_zone='+00:00'을 설정한다.
-- 배치 로더는 미포함. 집계 키의 전체 결과를 트랜잭션으로 교체하며,
-- 재실행 시 카운트를 더하지 않는다. 갱신 시 refreshed_at도 명시적으로 갱신한다.

CREATE DATABASE IF NOT EXISTS shop_reporting CHARACTER SET utf8mb4;
SET time_zone = '+00:00';

CREATE TABLE shop_reporting.product_metric_keys
(
    metric_key_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    mall_id BIGINT UNSIGNED NOT NULL CHECK (mall_id > 0),
    store_id BIGINT UNSIGNED NOT NULL CHECK (store_id > 0),
    product_id BIGINT UNSIGNED NOT NULL CHECK (product_id > 0),
    `day` DATE NOT NULL COMMENT '대표 이벤트 occurred_at의 UTC 날짜',
    `hour` TINYINT UNSIGNED NOT NULL COMMENT '대표 이벤트 occurred_at의 UTC 시간' CHECK (`hour` BETWEEN 0 AND 23),
    UNIQUE (mall_id, store_id, product_id, `day`, `hour`)
) ENGINE = InnoDB;

CREATE INDEX product_metric_keys_lookup
ON shop_reporting.product_metric_keys (product_id, `day`, `hour`);

CREATE TABLE shop_reporting.product_metrics
(
    metric_key_id BIGINT UNSIGNED PRIMARY KEY,
    notify_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (notify_count >= 0),
    click_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (click_count >= 0),
    view_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (view_count >= 0),
    cart_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (cart_count >= 0),
    purchase_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (purchase_count >= 0),
    refreshed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    FOREIGN KEY (metric_key_id) REFERENCES shop_reporting.product_metric_keys (metric_key_id)
) ENGINE = InnoDB;

-- 현재 ERD의 고객 그룹별 통계에는 day/hour 및 product_id가 없다.
-- 그룹 간 다중 소속 때문에 이 통계의 합계를 상품 전체 합계로 사용하면 안 된다.
CREATE TABLE shop_reporting.group_metric_keys
(
    metric_key_id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    mall_id BIGINT UNSIGNED NOT NULL CHECK (mall_id > 0),
    store_id BIGINT UNSIGNED NOT NULL CHECK (store_id > 0),
    customer_group_id BIGINT UNSIGNED NOT NULL CHECK (customer_group_id > 0),
    UNIQUE (mall_id, store_id, customer_group_id)
) ENGINE = InnoDB;

CREATE TABLE shop_reporting.group_metrics
(
    metric_key_id BIGINT UNSIGNED PRIMARY KEY,
    notify_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (notify_count >= 0),
    click_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (click_count >= 0),
    view_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (view_count >= 0),
    cart_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (cart_count >= 0),
    purchase_count BIGINT UNSIGNED NOT NULL DEFAULT 0 CHECK (purchase_count >= 0),
    refreshed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    FOREIGN KEY (metric_key_id) REFERENCES shop_reporting.group_metric_keys (metric_key_id)
) ENGINE = InnoDB;
