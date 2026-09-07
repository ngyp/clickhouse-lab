package io.clickhouselab.pushclick;

import io.clickhouselab.pushclick.web.dto.CampaignStatsResponse;
import io.clickhouselab.pushclick.web.dto.CreateCustomerRequest;
import io.clickhouselab.pushclick.web.dto.RecordClickRequest;
import io.clickhouselab.pushclick.web.dto.RecordPushRequest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.ResponseEntity;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * kind-clickhouse-lab 라이브 클러스터(port-forward 필요)에 대고 도는 end-to-end
 * 테스트: 고객 생성 → 발송 기록 → 클릭 기록(같은 campaign_id) → 통계 조회 순으로
 * 호출해, campaign_realtime_stats 뷰가 실제로 CTR을 계산해 내는지 확인한다.
 *
 * <p>사전 조건: kubectl --context kind-clickhouse-lab -n clickhouse port-forward
 * svc/clickhouse-chi 8123:8123 9000:9000 이 떠 있고, schema/001_init.sql이
 * 적용되어 있어야 한다.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class CampaignStatsIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void recordPushAndClick_thenStatsReflectCtr() {
        long customerId = System.nanoTime() % 1_000_000_000L;
        long campaignId = System.nanoTime() % 1_000_000L;

        restTemplate.postForEntity(
                url("/api/customers"),
                new CreateCustomerRequest(customerId, "test-device-token", "test-segment"),
                Void.class
        );

        ResponseEntity<PushResponse> pushResponse = restTemplate.postForEntity(
                url("/api/pushes"),
                new RecordPushRequest(null, customerId, campaignId, "welcome-template"),
                PushResponse.class
        );
        assertThat(pushResponse.getStatusCode().is2xxSuccessful()).isTrue();
        UUID sendId = pushResponse.getBody().sendId();

        ResponseEntity<Void> clickResponse = restTemplate.postForEntity(
                url("/api/clicks"),
                new RecordClickRequest(sendId, customerId, campaignId),
                Void.class
        );
        assertThat(clickResponse.getStatusCode().is2xxSuccessful()).isTrue();

        // Materialized View는 백그라운드 병합/집계를 거치므로 즉시 반영이 보장되지
        // 않는다 — 짧게 재시도하며 통계가 채워지길 기다린다.
        CampaignStatsResponse stats = awaitStats(campaignId);

        assertThat(stats.hourly()).isNotEmpty();
        var latest = stats.hourly().get(stats.hourly().size() - 1);
        assertThat(latest.sentCount()).isGreaterThanOrEqualTo(1);
        assertThat(latest.clickCount()).isGreaterThanOrEqualTo(1);
        assertThat(latest.ctr()).isGreaterThan(0.0);
    }

    private CampaignStatsResponse awaitStats(long campaignId) {
        CampaignStatsResponse last = null;
        for (int i = 0; i < 10; i++) {
            last = restTemplate.getForObject(url("/api/campaigns/" + campaignId + "/stats?hours=1"), CampaignStatsResponse.class);
            if (last != null && !last.hourly().isEmpty()) {
                return last;
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return last;
    }

    private String url(String path) {
        return "http://localhost:" + port + path;
    }

    private record PushResponse(UUID sendId) {
    }
}
