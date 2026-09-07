package io.clickhouselab.pushclick.repository;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * ClickHouse 클러스터/레플리카 상태를 조회하는 진단 쿼리 모음.
 *
 * <p>여기서 확인하는 신호들은 GUIDE.md 12절("가시성")의 system.* 치트시트,
 * PRODUCTION.md 9절의 모니터링 알람 임계치 표와 동일한 근거에서 나온 것들이다 —
 * 일반적인 "DB 연결 가능한가"를 넘어, 이 랩에서 실제로 관찰했던 ClickHouse
 * 특유의 장애 신호(레플리카 지연/읽기전용 전환, Keeper 세션 끊김, 파트 적체)를
 * 이 마이크로서비스가 담당하는 push_click DB 범위로 좁혀 확인한다.
 */
@Repository
public class ClickHouseDiagnosticsRepository {

    private final JdbcTemplate jdbcTemplate;

    public ClickHouseDiagnosticsRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public record ReplicaStatus(
            String table,
            boolean readonly,
            long activeReplicas,
            long totalReplicas
    ) {
    }

    /**
     * system.replicas — is_readonly=1이면 Keeper 연결 문제, active_replicas &lt;
     * total_replicas면 일부 레플리카가 다운된 상태다 (GUIDE.md 12-1절).
     */
    public List<ReplicaStatus> replicaStatuses(String database) {
        return jdbcTemplate.query(
                """
                SELECT table, is_readonly, active_replicas, total_replicas
                FROM system.replicas
                WHERE database = ?
                ORDER BY table
                """,
                (rs, rowNum) -> new ReplicaStatus(
                        rs.getString("table"),
                        rs.getBoolean("is_readonly"),
                        rs.getLong("active_replicas"),
                        rs.getLong("total_replicas")
                ),
                database
        );
    }

    /**
     * 진행 중(미완료) mutation 수 — 오래 정체되면 배경 병합이 멈췄다는 신호
     * (GUIDE.md 16절: SYSTEM STOP MERGES 상태에서 겪은 문제).
     */
    public long pendingMutations(String database) {
        Long count = jdbcTemplate.queryForObject(
                "SELECT count() FROM system.mutations WHERE database = ? AND NOT is_done",
                Long.class,
                database
        );
        return count != null ? count : 0L;
    }

    /**
     * 테이블별 활성 파트 수 — parts_to_delay_insert(기본 1000)/
     * parts_to_throw_insert(기본 3000)에 근접하면 INSERT가 지연/거부될 수 있다
     * (PRODUCTION.md 4절).
     */
    public Map<String, Long> activePartsByTable(String database) {
        Map<String, Long> result = new LinkedHashMap<>();
        jdbcTemplate.query(
                """
                SELECT table, count() AS parts
                FROM system.parts
                WHERE database = ? AND active
                GROUP BY table
                ORDER BY table
                """,
                rs -> {
                    result.put(rs.getString("table"), rs.getLong("parts"));
                },
                database
        );
        return result;
    }

    /**
     * 이 노드가 Keeper와 맺은 세션이 살아있는지 (GUIDE.md 12-1절
     * system.zookeeper_connection). 세션이 끊기면 이 조회 자체가 빈 결과를
     * 반환하거나 예외를 던질 수 있으므로 방어적으로 처리한다.
     */
    public boolean keeperConnected() {
        try {
            Long count = jdbcTemplate.queryForObject(
                    "SELECT count() FROM system.zookeeper_connection",
                    Long.class
            );
            return count != null && count > 0;
        } catch (Exception e) {
            return false;
        }
    }
}
