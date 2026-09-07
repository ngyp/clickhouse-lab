package io.clickhouselab.pushclick.repository;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;

/**
 * ReplacingMergeTree 기반 upsert. INSERT는 즉시 반영되지만, 같은 customer_id의
 * 이전 행은 백그라운드 병합 시점에야 실제로 제거된다 — 조회 시 최신값만
 * 보려면 {@code FINAL} 또는 {@code argMax}를 써야 한다 (여기서는 스켈레톤
 * 범위상 조회 API를 두지 않았으므로 생략).
 */
@Repository
public class CustomerRepository {

    private final JdbcTemplate jdbcTemplate;

    public CustomerRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public void upsert(long customerId, String deviceToken, String segment) {
        jdbcTemplate.update(
                """
                INSERT INTO push_click.customers (customer_id, device_token, segment, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                customerId,
                deviceToken,
                segment,
                LocalDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS),
                LocalDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS)
        );
    }
}
