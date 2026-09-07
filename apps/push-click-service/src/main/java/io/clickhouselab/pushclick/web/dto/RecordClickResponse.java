package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;

import java.util.UUID;

@Schema(description = "Confirmation that a click event was accepted.")
public record RecordClickResponse(

        @Schema(description = "Server-generated identifier for this click event.")
        UUID clickId
) {
}
