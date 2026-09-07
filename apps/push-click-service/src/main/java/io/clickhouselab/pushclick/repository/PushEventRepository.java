package io.clickhouselab.pushclick.repository;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

@Repository
public class PushEventRepository {

    private final JdbcTemplate jdbcTemplate;

    public PushEventRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public void record(UUID sendId, long customerId, long campaignId, String templateId) {
        jdbcTemplate.update(
                """
                INSERT INTO push_click.pushes (send_id, customer_id, campaign_id, template_id, sent_at, status)
                VALUES (?, ?, ?, ?, ?, 'SENT')
                """,
                sendId.toString(),
                customerId,
                campaignId,
                templateId,
                // sent_at 컬럼은 DateTime(초 단위, 소수점 불가). java.sql.Timestamp를
                // 바인딩하면 나노초가 0이어도 toString()이 항상 ".0"을 붙여
                // "Expected ',' after the value of column sent_at" 구문 오류가 나고,
                // JVM 기본 타임존으로 직렬화되어 서버(UTC)와 어긋날 수도 있다 —
                // UTC LocalDateTime을 초 단위로 잘라 직접 바인딩한다.
                LocalDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS)
        );
    }
}
