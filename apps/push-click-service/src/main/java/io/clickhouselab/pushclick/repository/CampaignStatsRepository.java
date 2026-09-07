package io.clickhouselab.pushclick.repository;

import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * push_stats/click_stats(둘 다 Materialized View로 채워지는 사전집계 테이블)를
 * 조회 시점에 조인하는 {@code campaign_realtime_stats} 뷰를 읽는다.
 * 이 뷰 자체는 Materialized가 아니라 일반 VIEW이므로, 매 조회마다 실행되지만
 * 원본 이벤트가 아닌 이미 campaign x hour 단위로 작아진 데이터를 조인하므로
 * 비용이 낮다.
 */
@Repository
public class CampaignStatsRepository {

    private final JdbcTemplate jdbcTemplate;

    public CampaignStatsRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public List<CampaignStatsResponse.HourlyStat> findHourlyStats(long campaignId, int hours) {
        return jdbcTemplate.query(
                """
                SELECT hour, sent_count, click_count, unique_clickers, ctr
                FROM push_click.campaign_realtime_stats
                WHERE campaign_id = ? AND hour >= now() - INTERVAL ? HOUR
                ORDER BY hour
                """,
                (rs, rowNum) -> new CampaignStatsResponse.HourlyStat(
                        rs.getTimestamp("hour").toLocalDateTime(),
                        rs.getLong("sent_count"),
                        rs.getLong("click_count"),
                        rs.getLong("unique_clickers"),
                        rs.getDouble("ctr")
                ),
                campaignId, hours
        );
    }
}
