package io.clickhouselab.pushclick.service;

import io.clickhouselab.pushclick.repository.ClickEventRepository;
import io.clickhouselab.pushclick.web.dto.RecordClickRequest;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class ClickEventService {

    private final ClickEventRepository clickEventRepository;

    public ClickEventService(ClickEventRepository clickEventRepository) {
        this.clickEventRepository = clickEventRepository;
    }

    public UUID record(RecordClickRequest request) {
        UUID clickId = UUID.randomUUID();
        clickEventRepository.record(clickId, request.sendId(), request.customerId(), request.campaignId());
        return clickId;
    }
}
