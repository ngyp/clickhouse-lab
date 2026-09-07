package io.clickhouselab.pushclick.actuator;

import io.clickhouselab.pushclick.repository.ClickHouseDiagnosticsRepository;
import io.clickhouselab.pushclick.repository.ClickHouseDiagnosticsRepository.ReplicaStatus;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.boot.actuate.health.Status;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

/**
 * push_click 스키마에 대한 ClickHouse 클러스터 상태를 확인하는 커스텀
 * Actuator HealthIndicator.
 *
 * <p>Spring Boot가 spring-boot-starter-jdbc로 이미 자동 등록해주는
 * {@code db} HealthIndicator는 "연결이 되는가"(SELECT 1 수준)만 확인한다.
 * ClickHouse는 그보다 훨씬 더 특유의 실패 모드를 가진다 — 연결은 되지만
 * 실제로는 저하된 상태(레플리카 읽기전용 전환, Keeper 세션 단절, 파트 적체로
 * 곧 INSERT가 거부될 상황)일 수 있다. 이 인디케이터는 이 랩에서 실제로 겪은
 * 그 장애들(GUIDE.md 7/10/16절)을 판별 기준으로 삼는다.
 *
 * <p>판정 기준:
 * <ul>
 *   <li>{@code is_readonly=1}인 레플리카가 하나라도 있으면 → DOWN (Keeper 쿼럼
 *       상실 시 나타나는 신호, GUIDE.md 10절에서 재현)</li>
 *   <li>{@code active_replicas < total_replicas}인 테이블이 있으면 → DOWN
 *       (레플리카 다운, GUIDE.md 7-2절에서 재현)</li>
 *   <li>Keeper 세션이 끊겨 있으면 → DOWN</li>
 *   <li>테이블 활성 파트 수가 {@code parts_to_delay_insert}(기본 1000)를
 *       넘으면 → OUT_OF_SERVICE (곧 INSERT 지연/거부 위험, PRODUCTION.md 4절)</li>
 *   <li>그 외 → UP</li>
 * </ul>
 * 모든 경우에 상세 지표(레플리카별 상태, 미완료 mutation 수, 테이블별 파트
 * 수)를 details로 함께 반환해, 단순 UP/DOWN보다 풍부한 운영 정보를 준다.
 */
@Component
public class ClickHouseClusterHealthIndicator implements HealthIndicator {

    /** ClickHouse 기본값(PRODUCTION.md 4절) — 이 이상이면 INSERT가 지연되기 시작한다. */
    private static final long PARTS_TO_DELAY_INSERT_DEFAULT = 1000;

    private static final String DATABASE = "push_click";

    private final ClickHouseDiagnosticsRepository diagnostics;

    public ClickHouseClusterHealthIndicator(ClickHouseDiagnosticsRepository diagnostics) {
        this.diagnostics = diagnostics;
    }

    @Override
    public Health health() {
        try {
            List<ReplicaStatus> replicas = diagnostics.replicaStatuses(DATABASE);
            long pendingMutations = diagnostics.pendingMutations(DATABASE);
            Map<String, Long> activeParts = diagnostics.activePartsByTable(DATABASE);
            boolean keeperConnected = diagnostics.keeperConnected();

            Health.Builder builder = Health.up();

            List<String> readonlyTables = replicas.stream()
                    .filter(ReplicaStatus::readonly)
                    .map(ReplicaStatus::table)
                    .toList();
            List<String> degradedTables = replicas.stream()
                    .filter(r -> r.activeReplicas() < r.totalReplicas())
                    .map(ReplicaStatus::table)
                    .toList();
            List<String> partsNearThreshold = activeParts.entrySet().stream()
                    .filter(e -> e.getValue() >= PARTS_TO_DELAY_INSERT_DEFAULT)
                    .map(Map.Entry::getKey)
                    .toList();

            if (!readonlyTables.isEmpty() || !degradedTables.isEmpty() || !keeperConnected) {
                builder = Health.down();
            } else if (!partsNearThreshold.isEmpty()) {
                builder = Health.status(Status.OUT_OF_SERVICE);
            }

            return builder
                    .withDetail("keeperConnected", keeperConnected)
                    .withDetail("readonlyTables", readonlyTables)
                    .withDetail("degradedReplicaTables", degradedTables)
                    .withDetail("pendingMutations", pendingMutations)
                    .withDetail("activePartsByTable", activeParts)
                    .withDetail("partsNearDelayThreshold", partsNearThreshold)
                    .build();
        } catch (Exception e) {
            return Health.down(e).build();
        }
    }
}
