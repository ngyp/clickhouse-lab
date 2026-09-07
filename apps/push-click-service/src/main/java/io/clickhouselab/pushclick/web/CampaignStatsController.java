package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.CampaignStatsService;
import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
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
public class CampaignStatsController {

    private final CampaignStatsService campaignStatsService;

    public CampaignStatsController(CampaignStatsService campaignStatsService) {
        this.campaignStatsService = campaignStatsService;
    }

    @GetMapping("/{campaignId}/stats")
    public CampaignStatsResponse stats(
            @PathVariable @Positive long campaignId,
            // hours에 상한이 없으면 `now() - INTERVAL ? HOUR`가 임의로 큰 범위를
            // 스캔하게 만들 수 있다 (리소스 소모 유발) — 최대 7일(168시간)로 제한.
            @RequestParam(defaultValue = "24") @Min(1) @Max(168) int hours
    ) {
        return campaignStatsService.getStats(campaignId, hours);
    }
}
