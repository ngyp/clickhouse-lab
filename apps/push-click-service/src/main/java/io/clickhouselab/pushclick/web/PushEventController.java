package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.PushEventService;
import io.clickhouselab.pushclick.web.dto.RecordPushRequest;
import io.clickhouselab.pushclick.web.dto.RecordPushResponse;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/pushes")
@Tag(name = "Pushes", description = "Record push-notification send events.")
public class PushEventController {

    private final PushEventService pushEventService;

    public PushEventController(PushEventService pushEventService) {
        this.pushEventService = pushEventService;
    }

    @Operation(
            operationId = "recordPushEvent",
            summary = "Record a push-notification send",
            description = "Records that a push notification was sent to a customer as part of a campaign. " +
                    "The returned sendId must be saved and passed back when recording the corresponding " +
                    "click via recordClickEvent, so that click-through statistics can be correctly " +
                    "attributed to this campaign."
    )
    @ApiResponse(responseCode = "202", description = "The push-send event was accepted and will be written asynchronously.")
    @PostMapping
    public ResponseEntity<RecordPushResponse> record(@Valid @RequestBody RecordPushRequest request) {
        var sendId = pushEventService.record(request);
        return ResponseEntity.accepted().body(new RecordPushResponse(sendId));
    }
}
