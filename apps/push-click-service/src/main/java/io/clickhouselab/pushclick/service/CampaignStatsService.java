package io.clickhouselab.pushclick.service;

import io.clickhouselab.pushclick.repository.CampaignStatsRepository;
import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
import org.springframework.stereotype.Service;

@Service
public class CampaignStatsService {

    private final CampaignStatsRepository campaignStatsRepository;

    public CampaignStatsService(CampaignStatsRepository campaignStatsRepository) {
        this.campaignStatsRepository = campaignStatsRepository;
    }

    public CampaignStatsResponse getStats(long campaignId, int hours) {
        var hourly = campaignStatsRepository.findHourlyStats(campaignId, hours);
        return new CampaignStatsResponse(campaignId, hourly);
    }
}
