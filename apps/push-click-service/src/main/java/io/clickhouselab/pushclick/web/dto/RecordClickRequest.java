package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.util.UUID;

@Schema(description = "Request to record that a customer clicked on a previously sent push notification. " +
        "campaignId must be repeated here (rather than looked up from sendId) so that click statistics " +
        "can be aggregated independently from push-send statistics, without a real-time join between the two.")
public record RecordClickRequest(

        @Schema(description = "The sendId that was returned when the corresponding push notification was recorded via recordPushEvent.", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull UUID sendId,

        @Schema(description = "The customer who clicked. Should match the customerId used in the original recordPushEvent call.", example = "1001", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull @Positive Long customerId,

        @Schema(description = "The campaign this click belongs to. Should match the campaignId used in the original recordPushEvent call.", example = "5001", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull @Positive Long campaignId
) {
}
