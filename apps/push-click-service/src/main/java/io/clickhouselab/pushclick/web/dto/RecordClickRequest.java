package io.clickhouselab.pushclick.web.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.util.UUID;

public record RecordClickRequest(
        @NotNull UUID sendId,
        @NotNull @Positive Long customerId,
        @NotNull @Positive Long campaignId
) {
}
