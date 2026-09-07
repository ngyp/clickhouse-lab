package io.clickhouselab.pushclick.web.dto;

import io.swagger.v3.oas.annotations.media.Schema;

import java.util.UUID;

@Schema(description = "Confirmation that a push-send event was accepted, with the identifier needed to later record its click.")
public record RecordPushResponse(

        @Schema(description = "Identifier of this push send. Save this value and pass it as sendId when calling recordClickEvent for the same push.")
        UUID sendId
) {
}
