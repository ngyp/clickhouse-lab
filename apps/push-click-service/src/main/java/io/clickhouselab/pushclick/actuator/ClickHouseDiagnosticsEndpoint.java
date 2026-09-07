package io.clickhouselab.pushclick.actuator;

import io.clickhouselab.pushclick.repository.ClickHouseDiagnosticsRepository;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

import java.util.Map;

/**
 * {@code GET /actuator/clickhouse} — HealthIndicator보다 더 풍부한, ClickHouse
 * 운영자가 curl 한 번으로 훑어볼 수 있는 진단 스냅샷을 제공하는 커스텀
 * Actuator 엔드포인트.
 *
 * <p>HealthIndicator는 "UP이냐 아니냐"로 요약해야 하지만, 실제 장애 대응에는
 * "레플리카별로 정확히 뭐가 문제인지", "어느 테이블에 파트가 몇 개 쌓였는지"
 * 같은 원본에 가까운 수치가 필요하다. 이 엔드포인트는 그 간극을 메운다 —
 * GUIDE.md 12-1절의 system.* 치트시트를 애플리케이션이 직접 노출하는 셈이다.
 *
 * <p>{@code management.server.port}(기본 8081, application.yml)로 분리된
 * 관리용 포트에서만 서비스되므로, 클러스터 내부 토폴로지/레플리카 상태 같은
 * 민감한 운영 정보가 외부 API 포트(8080)로 새어나가지 않는다.
 */
@Component
@Endpoint(id = "clickhouse")
public class ClickHouseDiagnosticsEndpoint {

    private static final String DATABASE = "push_click";

    private final ClickHouseDiagnosticsRepository diagnostics;

    public ClickHouseDiagnosticsEndpoint(ClickHouseDiagnosticsRepository diagnostics) {
        this.diagnostics = diagnostics;
    }

    @ReadOperation
    public Map<String, Object> diagnostics() {
        return Map.of(
                "database", DATABASE,
                "keeperConnected", diagnostics.keeperConnected(),
                "replicas", diagnostics.replicaStatuses(DATABASE),
                "pendingMutations", diagnostics.pendingMutations(DATABASE),
                "activePartsByTable", diagnostics.activePartsByTable(DATABASE)
        );
    }
}
