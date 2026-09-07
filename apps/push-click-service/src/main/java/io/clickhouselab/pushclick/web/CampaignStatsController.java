package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.CampaignStatsService;
import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/campaigns")
public class CampaignStatsController {

    private final CampaignStatsService campaignStatsService;

    public CampaignStatsController(CampaignStatsService campaignStatsService) {
        this.campaignStatsService = campaignStatsService;
    }

    @GetMapping("/{campaignId}/stats")
    public CampaignStatsResponse stats(
            @PathVariable long campaignId,
            @RequestParam(defaultValue = "24") int hours
    ) {
        return campaignStatsService.getStats(campaignId, hours);
    }
}
