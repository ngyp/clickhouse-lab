package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.ClickEventService;
import io.clickhouselab.pushclick.web.dto.RecordClickRequest;
import io.clickhouselab.pushclick.web.dto.RecordClickResponse;
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
@RequestMapping("/api/clicks")
@Tag(name = "Clicks", description = "Record push-notification click events.")
public class ClickEventController {

    private final ClickEventService clickEventService;

    public ClickEventController(ClickEventService clickEventService) {
        this.clickEventService = clickEventService;
    }

    @Operation(
            operationId = "recordClickEvent",
            summary = "Record a push-notification click",
            description = "Records that a customer clicked on a previously sent push notification. " +
                    "Requires the sendId returned by recordPushEvent for that push, along with the same " +
                    "customerId and campaignId, so the click can be correctly attributed to its campaign " +
                    "for CTR reporting."
    )
    @ApiResponse(responseCode = "202", description = "The click event was accepted and will be written asynchronously.")
    @PostMapping
    public ResponseEntity<RecordClickResponse> record(@Valid @RequestBody RecordClickRequest request) {
        var clickId = clickEventService.record(request);
        return ResponseEntity.accepted().body(new RecordClickResponse(clickId));
    }
}
