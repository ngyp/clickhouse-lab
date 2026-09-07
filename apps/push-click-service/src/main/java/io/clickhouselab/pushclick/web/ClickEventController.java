package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.ClickEventService;
import io.clickhouselab.pushclick.web.dto.RecordClickRequest;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/clicks")
public class ClickEventController {

    private final ClickEventService clickEventService;

    public ClickEventController(ClickEventService clickEventService) {
        this.clickEventService = clickEventService;
    }

    @PostMapping
    public ResponseEntity<Map<String, UUID>> record(@Valid @RequestBody RecordClickRequest request) {
        UUID clickId = clickEventService.record(request);
        return ResponseEntity.accepted().body(Map.of("clickId", clickId));
    }
}
