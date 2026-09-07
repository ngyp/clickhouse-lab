package io.clickhouselab.pushclick.web.dto;

import java.time.LocalDateTime;
import java.util.List;

public record CampaignStatsResponse(
        long campaignId,
        List<HourlyStat> hourly
) {
    public record HourlyStat(
            LocalDateTime hour,
            long sentCount,
            long clickCount,
            long uniqueClickers,
            double ctr
    ) {
    }
}
