# push-click-service

ClickHouse + Spring Boot(Maven) 표준 스켈레톤 — 앱 푸시 **발송**과 사용자
**클릭** 로그를 저장하고, **Materialized View**로 캠페인별 실시간 CTR(클릭률)을
집계하는 마이크로서비스입니다.

이 저장소의 [GUIDE.md](../../GUIDE.md)(랩 재현 가이드), [PRODUCTION.md](../../PRODUCTION.md)
(프로덕션 운영 가이드) 위에서 동작하는 실제 예제 애플리케이션입니다. 로컬
개발은 이 저장소 루트의 kind 랩 클러스터(4샤드×3레플리카 + Keeper)를 그대로
재사용합니다.

## 아키텍처

```
customers (고객)          pushes (발송)              clicks (클릭)
ReplacingMergeTree        ReplicatedMergeTree         ReplicatedMergeTree
     |                         |                            |
     |                         v                            v
     |                  push_stats_mv                click_stats_mv
     |                  (campaign,hour)              (campaign,hour)
     |                  AggregatingMergeTree          AggregatingMergeTree
     |                         |                            |
     |                         +------------+---------------+
     |                                      v
     |                       campaign_realtime_stats (VIEW)
     |                       GLOBAL LEFT JOIN로 조회 시점에 병합 → CTR
     v
  (스켈레톤 범위상 조회 API 없음 — 조인용 마스터 데이터로만 사용)
```

### 핵심 설계: 왜 "발송 JOIN 클릭"을 하나의 MV로 만들지 않았는가

ClickHouse의 Materialized View는 **원본 테이블 한쪽에 INSERT될 때만 트리거**
되는 "per-source-table" 트리거입니다. 발송과 클릭을 실시간 JOIN하는 단일 MV를
만들면, 클릭이 나중에 도착해도 발송 쪽 MV가 재계산되지 않아 결과가 틀어집니다.

대신:
1. 클릭 이벤트에 `campaign_id`를 **쓰기 시점에 미리 태깅**(발송과 별개로 앱이
   직접 넣어줌) — 조인 없이 두 스트림을 독립적으로 집계 가능하게 함
2. `push_stats_mv`/`click_stats_mv`가 각각 독립적으로 `AggregatingMergeTree`에
   `(campaign_id, hour)` 단위 집계 상태를 유지
3. 조회 시점에 이 두 사전집계 결과를 가볍게 조인하는 **일반 VIEW**
   (`campaign_realtime_stats`, Materialized 아님)로 CTR 제공

## Quickstart

### 0. 사전 조건

- 이 저장소 루트의 kind 랩 클러스터(`kind-clickhouse-lab`)가 떠 있어야 합니다
  (없다면 [GUIDE.md](../../GUIDE.md) 0~6절 참고).
- Java 21, Maven. `JAVA_HOME`을 명시적으로 21로 고정하는 걸 권장합니다
  (`/usr/libexec/java_home -V`로 설치된 JDK 확인).

### 1. 스키마 적용

```bash
cat src/main/resources/schema/001_init.sql | \
  kubectl --context kind-clickhouse-lab -n clickhouse exec -i chi-chi-cluster1-0-0-0 \
  -- clickhouse-client --multiquery

kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 \
  -- clickhouse-client -q "SHOW TABLES FROM push_click"
```

### 2. 전용 애플리케이션 사용자 생성

`default` 사용자(빈 비밀번호) 대신, `push_click` DB에만 권한을 가진 전용
사용자를 씁니다 (PRODUCTION.md 10절 권고):

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE USER push_click_app ON CLUSTER 'cluster1' IDENTIFIED WITH sha256_password BY '<원하는 비밀번호>'
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
GRANT ON CLUSTER 'cluster1' SELECT, INSERT ON push_click.* TO push_click_app
"
# 아래 4개는 애플리케이션 데이터가 아니라 시스템 테이블 권한이다 — Actuator의
# ClickHouseClusterHealthIndicator/진단 엔드포인트가 레플리카·뮤테이션·파트·
# Keeper 세션 상태를 조회하는 데 필요하다 ("Actuator 패턴" 절 참고). 이것도
# push_click.* 권한과 마찬가지로 SELECT만 부여하는 최소 권한 원칙을 지킨다.
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
GRANT ON CLUSTER 'cluster1' SELECT ON system.replicas TO push_click_app
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
GRANT ON CLUSTER 'cluster1' SELECT ON system.mutations TO push_click_app
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
GRANT ON CLUSTER 'cluster1' SELECT ON system.parts TO push_click_app
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
GRANT ON CLUSTER 'cluster1' SELECT ON system.zookeeper_connection TO push_click_app
"
```

비밀번호는 **소스에 하드코딩하지 않습니다** — `CLICKHOUSE_PASSWORD` 환경변수로
주입합니다 (자세한 내용은 "시큐어 코딩" 절 참고):

```bash
export CLICKHOUSE_PASSWORD='<위에서 정한 비밀번호>'
```

### 3. Port-forward

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward --address 127.0.0.1 \
  svc/clickhouse-chi 18123:8123 19000:9000
```

> **왜 8123/9000이 아니라 18123/19000인가?** "알려진 이슈" 절 참고 — 이
> 머신에 이미 다른 프로세스(예: 다른 docker-compose 스택)가 `127.0.0.1:8123`을
> 점유하고 있을 수 있습니다.

### 4. 빌드 & 실행

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
mvn spring-boot:run
```

### 5. API 호출

```bash
# 고객 생성
curl -X POST http://localhost:8080/api/customers \
  -H "Content-Type: application/json" \
  -d '{"customerId": 1001, "deviceToken": "device-abc", "segment": "vip"}'

# 발송 기록
SEND_ID=$(curl -s -X POST http://localhost:8080/api/pushes \
  -H "Content-Type: application/json" \
  -d '{"customerId": 1001, "campaignId": 5001, "templateId": "welcome"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['sendId'])")

# 클릭 기록 (같은 campaignId를 함께 태깅)
curl -X POST http://localhost:8080/api/clicks \
  -H "Content-Type: application/json" \
  -d "{\"sendId\": \"$SEND_ID\", \"customerId\": 1001, \"campaignId\": 5001}"

# 실시간 통계 조회 (MV 반영에 수 초 걸릴 수 있어 재시도)
curl "http://localhost:8080/api/campaigns/5001/stats?hours=1"
# => {"campaignId":5001,"hourly":[{"hour":"...","sentCount":1,"clickCount":1,"uniqueClickers":1,"ctr":1.0}]}

# 헬스체크/진단은 별도 관리 포트(8081)에서 (아래 "Actuator 패턴" 절 참고)
curl http://localhost:8081/actuator/health
curl http://localhost:8081/actuator/clickhouse
```

### 6. 테스트

```bash
mvn test
```

`PushClickServiceApplicationTests`(컨텍스트 로드)와
`CampaignStatsIntegrationTest`(고객→발송→클릭→통계 조회 end-to-end, 라이브
클러스터 필요) 둘 다 위 1~3단계가 완료된 상태를 전제로 합니다.

## 알려진 이슈 (실제로 겪은 함정들)

이 스켈레톤을 만들며 실제로 부딪힌 문제들입니다 — 다른 프로젝트에서 ClickHouse
+ Java를 조합할 때도 똑같이 겪을 수 있어 기록해둡니다.

### 1. Distributed 테이블끼리 JOIN하면 "Double-distributed" 에러

`campaign_realtime_stats`에서 `push_stats`(Distributed)와
`click_stats`(Distributed)를 그냥 `JOIN`하면:

```
Code: 288. DB::Exception: Double-distributed IN/JOIN subqueries is denied
(distributed_product_mode = 'deny')
```

각 샤드가 오른쪽 테이블을 다시 분산 서브쿼리로 흩뿌리려다 막히는 것입니다.
**`GLOBAL LEFT JOIN`**을 쓰면 오른쪽 결과를 한 번만 계산해 각 샤드에
브로드캐스트하므로 해결됩니다 (두 결과 모두 campaign×hour 단위로 이미 작아서
브로드캐스트 비용도 낮습니다).

### 2. `DateTime` 컬럼에 `java.sql.Timestamp`를 바인딩하면 구문 오류

```
Code: 62. DB::Exception: Expected ',' after the value of column `sent_at` of
type DateTime here: 2026-09-07 14:29:33.0, 'SENT')
```

`sent_at`은 초 단위 `DateTime`인데, `java.sql.Timestamp.toString()`은 나노초가
0이어도 항상 `.0`을 붙입니다 — `DateTime`(소수점 불가, `DateTime64`만 지원)에
바인딩하면 구문 오류가 납니다. 게다가 `Timestamp.toString()`은 **JVM 기본
타임존**으로 직렬화되어 서버 타임존(우리 클러스터는 UTC)과 어긋날 수도
있습니다. 해결: `Timestamp` 대신 `java.time.LocalDateTime.now(ZoneOffset.UTC)
.truncatedTo(ChronoUnit.SECONDS)`를 직접 바인딩합니다
(`ClickEventRepository`/`PushEventRepository`/`CustomerRepository` 참고).

### 3. clickhouse-jdbc의 `compress=1` 응답을 LZ4로 잘못 해석

```
java.sql.SQLException: Invalid LZ4 magic byte: '-112'
```

클라이언트가 `Accept-Encoding: gzip`도 함께 보내면, 서버가 `compress=1`이
기대하는 ClickHouse 자체 LZ4 프레이밍 대신 표준 HTTP gzip으로 응답할 때가
있고, 드라이버는 이를 LZ4로 잘못 해석해 깨집니다. JDBC URL에 `compress=false`를
추가해 우회합니다 (`application.yml`/`application-incluster.yml` 참고).

### 4. 로컬 포트 충돌: `127.0.0.1:8123`을 다른 프로세스가 이미 점유

`kubectl port-forward`가 IPv6 루프백(`[::1]:8123`)에만 바인딩되고, 정작
IPv4(`127.0.0.1:8123`)는 이미 다른 프로세스(예: 다른 docker-compose 스택의
포트 포워딩)가 쥐고 있는 경우가 있었습니다. `curl`/`python`은 `localhost`를
IPv6로 우선 해석해 정상 동작했지만, Java(Apache HttpClient5)는 IPv4를 우선
시도해 **완전히 다른(관계없는) 서버**에 연결되어 알쏭달쏭한
`AUTHENTICATION_FAILED`를 냈습니다. `lsof -nP -iTCP:8123`으로 포트 점유
상태를 확인한 뒤, 충돌 없는 포트(예: 18123)로 `--address 127.0.0.1`을 명시해
port-forward하는 것으로 해결했습니다. **이 인증 오류가 나면 가장 먼저 포트
충돌 여부부터 확인하세요** — 자격증명 문제가 아닐 수 있습니다.

## 시큐어 코딩

이 스켈레톤을 만들며 실제로 점검·수정한 시큐어 코딩 항목들입니다.

### 1. 비밀번호를 소스에 하드코딩하지 않는다

처음엔 `application.yml`에 `password: "PushClickApp2026xyz"`처럼 평문 리터럴이
그대로 들어 있었습니다 — 저장소에 커밋되면 git 히스토리에 영구히 남는
전형적인 시크릿 노출입니다. `password: ${CLICKHOUSE_PASSWORD}`로 바꿔
**소스에는 플레이스홀더만** 남기고, 실제 값은:
- 로컬 개발: `export CLICKHOUSE_PASSWORD=...` 환경변수
- Kubernetes 배포: `Secret` + `envFrom`(또는 `valueFrom.secretKeyRef`)
- 실운영: AWS Secrets Manager 등에서 External Secrets Operator로 동기화
  (PRODUCTION-AWS.md 10절 참고)

로 주입받도록 했습니다. (`java.sql.Timestamp`/`java.sql.PreparedStatement`처럼
JDBC API 자체가 자격증명을 결국 `String`으로 요구하는 지점이 있어 — 메모리에서
명시적으로 지울 수 있는 `char[]`로 완전히 대체하지는 못합니다. 대신 "소스에
남기지 않는다"에 집중했습니다.)

### 2. SQL 인젝션 — 전 구간 파라미터 바인딩 확인

모든 Repository가 `JdbcTemplate`의 `?` 플레이스홀더 바인딩만 사용하고, 문자열
연결(`+`)이나 `String.format`으로 SQL을 조립하는 코드는 없습니다
(`ClickHouseDiagnosticsRepository`의 `database` 파라미터처럼 상수나 다름없는
값도 예외 없이 바인딩합니다).

### 3. 입력값 경계 검증 + 예외를 올바른 HTTP 상태로 매핑

`GET /api/campaigns/{campaignId}/stats?hours=N`에 `hours` 상한이 없으면
`now() - INTERVAL N HOUR`가 임의로 큰 범위를 스캔하게 만들 수 있습니다
(리소스 소모 벡터). `@Min(1) @Max(168)`(최대 7일)로 제한하고, `campaignId`도
`@Positive`로 제약했습니다.

`@RequestParam`/`@PathVariable` 제약 위반은 `@Valid @RequestBody`와 달리
스프링이 자동으로 400으로 변환해주지 않고 기본적으로 500(서버 내부 오류처럼
보임)으로 노출됩니다 — `GlobalExceptionHandler`에서
`ConstraintViolationException`을 명시적으로 400으로 매핑했습니다.

### 4. 최소 권한 원칙과 관측 가능성의 충돌 지점

Actuator용 헬스체크(`system.replicas`/`system.mutations`/`system.parts`/
`system.zookeeper_connection` 조회)를 추가하다가 `Not enough privileges`
오류를 만났습니다 — `push_click_app`에게는 애초에 `push_click.*`에 대한
`SELECT, INSERT`만 부여했기 때문입니다(의도한 최소 권한). 시스템 테이블
접근이 필요하다고 해서 무심코 넓은 권한(`GRANT SELECT ON *.*` 등)을 주지
않고, **정확히 필요한 4개 시스템 테이블에만** 개별 `GRANT`를 추가했습니다
(Quickstart 2단계). 최소 권한 원칙은 "필요한 게 생기면 그때그때 좁게
추가"하는 것이지, 문제가 생겼다고 권한을 뭉텅이로 넓히는 게 아니라는
예시입니다.

## Actuator 패턴 (ClickHouse 특성 반영)

Spring Boot가 `spring-boot-starter-jdbc`만으로 자동 등록해주는 `db`
HealthIndicator는 "연결이 되는가"(`isValid()`)만 확인합니다. 하지만 이
저장소의 실험들(GUIDE.md 7/10/16절)이 보여주듯, ClickHouse는 **연결은
멀쩡한데 실제로는 저하된 상태**일 수 있습니다 — 레플리카가 읽기전용으로
전환됐거나, Keeper 세션이 끊겼거나, 파트가 쌓여 곧 INSERT가 거부될 상황.
일반적인 "DB up/down" 헬스체크로는 이런 신호를 전혀 못 잡습니다.

### 커스텀 HealthIndicator: `ClickHouseClusterHealthIndicator`

`/actuator/health`의 `clickHouseCluster` 컴포넌트로 노출됩니다. 판정 기준은
전부 이 랩에서 실제로 재현했던 장애 신호(GUIDE.md 12-3절 "장애/이상 징후
판별 기준" 표와 동일)입니다:

| 신호 | 판정 |
|---|---|
| `is_readonly=1`인 레플리카 존재 | **DOWN** (Keeper 쿼럼 상실, GUIDE.md 10절) |
| `active_replicas < total_replicas`인 테이블 존재 | **DOWN** (레플리카 다운, GUIDE.md 7-2절) |
| Keeper 세션 끊김 | **DOWN** |
| 테이블 활성 파트 수 ≥ `parts_to_delay_insert`(기본 1000) | **OUT_OF_SERVICE** (곧 INSERT 지연, PRODUCTION.md 4절) |
| 위 전부 정상 | **UP** |

어느 상태든 레플리카별 상세, 미완료 뮤테이션 수, 테이블별 파트 수를 항상
`details`로 함께 반환해, 단순 UP/DOWN보다 실제 장애 대응에 쓸 수 있는
정보를 줍니다.

### 커스텀 엔드포인트: `GET /actuator/clickhouse`

HealthIndicator는 "요약"에 최적화돼 있어 표현할 수 있는 정보가 제한적입니다.
운영자가 curl 한 번으로 레플리카별 원본 수치를 훑어볼 수 있도록,
GUIDE.md 12-1절의 `system.*` 치트시트를 그대로 애플리케이션 엔드포인트로
노출하는 커스텀 `@Endpoint(id = "clickhouse")`를 추가했습니다.

### 왜 관리 포트를 분리했는가 (`server.port=8080` / `management.server.port=8081`)

레플리카 상태, Keeper 연결 여부 같은 정보는 클러스터 내부 토폴로지를
드러냅니다 — 인터넷에 노출된 API 포트로 함께 나가면 공격자에게 정찰 정보를
주는 셈입니다. `management.server.port`를 별도로 분리해 두면:
- 공개 API(`8080`)는 K8s Service/Ingress로 외부에 노출
- 관리 포트(`8081`)는 클러스터 내부에서만 접근(kubelet의 liveness/readiness
  probe, 내부 Prometheus 스크레이프 등) — Service를 만들지 않거나
  `NetworkPolicy`로 파드 간 접근만 허용

이 구조 덕분에 `management.endpoint.health.show-details: always`(상세 정보
전체 노출)로 설정해도 안전합니다 — 애초에 그 상세 정보가 나가는 포트 자체가
외부에서 도달 불가능하기 때문입니다.

## 다음 확장 아이디어

- **배치 INSERT**: 지금은 요청마다 단건 INSERT + `async_insert=1`로 서버가
  소량 INSERT를 모아주게 했습니다(PRODUCTION.md 4절). 처리량이 더 필요하면
  애플리케이션 레벨에서 이벤트를 버퍼링했다가 주기적으로 배치 INSERT하는
  방식으로 전환하세요.
- **진짜 고객 마스터 분리**: ClickHouse는 포인트 업데이트가 잦은 마스터
  데이터에는 최적이 아닙니다. 실무에서는 고객 마스터를 별도 RDB에 두고
  ClickHouse에는 조인용 스냅샷만 동기화하는 경우가 많습니다.
- **Kafka 연동**: 발송/클릭 이벤트량이 커지면 앱이 ClickHouse에 직접 쓰는 대신
  Kafka로 발행하고, ClickHouse의 `Kafka` 테이블 엔진 + MV로 소비하는 구조가
  안정성/버퍼링 면에서 유리합니다.
- **`incluster` 프로파일로 클러스터 안에 배포**: `application-incluster.yml`을
  참고해 이 서비스 자체를 CHI와 같은 네임스페이스의 Deployment로 배포하면,
  이 문서의 "알려진 이슈 4번"(포트 충돌)은 애초에 발생하지 않습니다.
