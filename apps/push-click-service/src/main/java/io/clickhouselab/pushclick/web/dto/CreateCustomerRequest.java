package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

@Schema(description = "Request to create a new customer or update an existing one (upsert by customerId).")
public record CreateCustomerRequest(

        @Schema(description = "Unique identifier of the customer.", example = "1001", requiredMode = Schema.RequiredMode.REQUIRED)
        @NotNull @Positive Long customerId,

        @Schema(description = "Push notification device token for this customer (e.g. an FCM/APNs token).", example = "device-abc123")
        @NotBlank String deviceToken,

        @Schema(description = "Marketing segment label used to group customers for targeting or reporting. Defaults to \"default\" if omitted.", example = "vip")
        String segment
) {
}
