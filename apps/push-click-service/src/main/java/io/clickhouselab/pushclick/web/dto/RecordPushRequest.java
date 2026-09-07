package io.clickhouselab.pushclick.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.util.UUID;

public record RecordPushRequest(
        UUID sendId,
        @NotNull @Positive Long customerId,
        @NotNull @Positive Long campaignId,
        @NotBlank String templateId
) {
    public UUID sendIdOrGenerate() {
        return sendId != null ? sendId : UUID.randomUUID();
    }
}
