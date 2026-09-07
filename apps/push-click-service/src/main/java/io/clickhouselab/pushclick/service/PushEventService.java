package io.clickhouselab.pushclick.service;

import io.clickhouselab.pushclick.repository.PushEventRepository;
import io.clickhouselab.pushclick.web.dto.RecordPushRequest;
import org.springframework.stereotype.Service;

import java.util.UUID;

@Service
public class PushEventService {

    private final PushEventRepository pushEventRepository;

    public PushEventService(PushEventRepository pushEventRepository) {
        this.pushEventRepository = pushEventRepository;
    }

    public UUID record(RecordPushRequest request) {
        UUID sendId = request.sendIdOrGenerate();
        pushEventRepository.record(sendId, request.customerId(), request.campaignId(), request.templateId());
        return sendId;
    }
}
