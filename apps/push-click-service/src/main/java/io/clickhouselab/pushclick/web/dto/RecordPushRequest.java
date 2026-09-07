package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.util.UUID;

@Schema(description = "Request to record that a push notification was sent to a customer as part of a campaign.")
public record RecordPushRequest(

        @Schema(description = "Optional client-supplied identifier for this send. If omitted, the server generates one and returns it in the response — callers must save it and pass it back later when recording the corresponding click.")
        UUID sendId,

        @Schema(description = "The customer the push was sent to.", example = "1001", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull @Positive Long customerId,

        @Schema(description = "The marketing campaign this push belongs to. Used to group sends and clicks for CTR reporting.", example = "5001", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull @Positive Long campaignId,

        @Schema(description = "Identifier of the push message template/content that was sent.", example = "welcome", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotBlank String templateId
) {
    public UUID sendIdOrGenerate() {
        return sendId != null ? sendId : UUID.randomUUID();
    }
}
