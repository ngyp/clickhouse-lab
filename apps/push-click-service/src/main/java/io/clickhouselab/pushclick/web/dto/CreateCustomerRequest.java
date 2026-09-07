package io.clickhouselab.pushclick.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

public record CreateCustomerRequest(
        @NotNull @Positive Long customerId,
        @NotBlank String deviceToken,
        String segment
) {
}
