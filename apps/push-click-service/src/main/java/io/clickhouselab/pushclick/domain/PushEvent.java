package io.clickhouselab.pushclick.domain;

import java.time.LocalDateTime;
import java.util.UUID;

public record PushEvent(
        UUID sendId,
        long customerId,
        long campaignId,
        String templateId,
        LocalDateTime sentAt,
        String status
) {
}
