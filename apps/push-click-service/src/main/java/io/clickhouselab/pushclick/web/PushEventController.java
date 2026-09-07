package io.clickhouselab.pushclick.web;

import io.clickhouselab.pushclick.service.PushEventService;
import io.clickhouselab.pushclick.web.dto.RecordPushRequest;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/pushes")
public class PushEventController {

    private final PushEventService pushEventService;

    public PushEventController(PushEventService pushEventService) {
        this.pushEventService = pushEventService;
    }

    @PostMapping
    public ResponseEntity<Map<String, UUID>> record(@Valid @RequestBody RecordPushRequest request) {
        UUID sendId = pushEventService.record(request);
        return ResponseEntity.accepted().body(Map.of("sendId", sendId));
    }
}
