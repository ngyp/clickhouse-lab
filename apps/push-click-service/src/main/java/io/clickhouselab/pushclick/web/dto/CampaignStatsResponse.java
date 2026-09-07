package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;

import java.time.LocalDateTime;
import java.util.List;

@Schema(description = "Real-time click-through-rate statistics for one campaign, bucketed by hour.")
public record CampaignStatsResponse(

        @Schema(description = "The campaign these statistics are for.", example = "5001")
        long campaignId,

        @Schema(description = "One entry per hour that had any push or click activity, ordered oldest to newest. Empty if no activity occurred in the requested time window.")
        List<HourlyStat> hourly
) {
    @Schema(description = "Push/click counters and computed CTR for a single hour bucket.")
    public record HourlyStat(

            @Schema(description = "Start of the hour bucket (UTC).")
            LocalDateTime hour,

            @Schema(description = "Number of push notifications sent for this campaign during this hour.", example = "1")
            long sentCount,

            @Schema(description = "Number of clicks recorded for this campaign during this hour.", example = "1")
            long clickCount,

            @Schema(description = "Number of distinct customers who clicked during this hour.", example = "1")
            long uniqueClickers,

            @Schema(description = "Click-through rate for this hour, computed as clickCount / sentCount. Ranges from 0.0 to 1.0 (or higher if a customer clicked multiple times).", example = "1.0")
            double ctr
    ) {
    }
}
