package io.clickhouselab.pushclick.repository;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

@Repository
public class ClickEventRepository {

    private final JdbcTemplate jdbcTemplate;

    public ClickEventRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public void record(UUID clickId, UUID sendId, long customerId, long campaignId) {
        jdbcTemplate.update(
                """
                INSERT INTO push_click.clicks (click_id, send_id, customer_id, campaign_id, clicked_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                clickId.toString(),
                sendId.toString(),
                customerId,
                campaignId,
                LocalDateTime.now(ZoneOffset.UTC).truncatedTo(ChronoUnit.SECONDS)
        );
    }
}
