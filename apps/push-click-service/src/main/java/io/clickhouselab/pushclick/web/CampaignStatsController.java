package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.CampaignStatsService;
import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Positive;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/campaigns")
@Validated
@Tag(name = "Campaign Stats", description = "Read real-time click-through-rate statistics computed from recorded pushes and clicks.")
public class CampaignStatsController {

    private final CampaignStatsService campaignStatsService;

    public CampaignStatsController(CampaignStatsService campaignStatsService) {
        this.campaignStatsService = campaignStatsService;
    }

    @Operation(
            operationId = "getCampaignStats",
            summary = "Get real-time campaign click-through-rate statistics",
            description = "Returns hourly-bucketed push-send count, click count, unique-clicker count, and " +
                    "click-through rate (CTR) for one campaign, covering the most recent N hours. Statistics " +
                    "reflect all recordPushEvent and recordClickEvent calls made for this campaignId; there " +
                    "may be a short delay (typically a few seconds) between an event being recorded and it " +
                    "appearing here, since the underlying aggregation runs asynchronously."
    )
    @GetMapping("/{campaignId}/stats")
    public CampaignStatsResponse stats(
            @Parameter(description = "The campaign to get statistics for.", example = "5001")
            @PathVariable @Positive long campaignId,

            // No upper bound would let `now() - INTERVAL ? HOUR` scan an arbitrarily
            // large range (a resource-exhaustion vector) — capped at 7 days (168h).
            @Parameter(description = "How many hours of history to include, counting back from now. Minimum 1, maximum 168 (7 days).", example = "24")
            @RequestParam(defaultValue = "24") @Min(1) @Max(168) int hours
    ) {
        return campaignStatsService.getStats(campaignId, hours);
    }
}
