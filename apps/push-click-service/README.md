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

Swagger UI: http://localhost:8080/swagger-ui.html (아래 "OpenAPI / Swagger /
AgentCore Gateway" 절 참고)

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

## OpenAPI / Swagger / AgentCore Gateway

이 서비스는 [springdoc-openapi](https://springdoc.org/)로 OpenAPI 스펙을 자동
생성합니다. 매 컨트롤러 메서드에 붙인 `@Operation`(영어 `summary`/
`description`)과 DTO의 `@Schema` 설명은 사람뿐 아니라 **AWS Bedrock
AgentCore Gateway처럼 OpenAPI 스펙을 읽어 LLM 에이전트용 도구로 변환하는
시스템**을 염두에 두고 영어로 작성했습니다 — Gateway는 각 operation을 MCP
툴로 노출하고, `summary`/`description`이 곧 LLM이 "이 툴을 언제 써야 하는지"
판단하는 근거가 되기 때문입니다.

- Swagger UI: `http://localhost:8080/swagger-ui.html`
- 원본 스펙(JSON): `http://localhost:8080/v3/api-docs`
- 저장소에 커밋된 정적 스냅샷: [`openapi.json`](./openapi.json)

### springdoc 버전에 관한 함정

`pom.xml`은 springdoc-openapi **2.6.0**을 씁니다. 최신 버전(2.8.x, 2.9.x)을
그대로 쓰면 부팅 시 다음 오류가 납니다:

```
NoClassDefFoundError: org/springframework/web/servlet/resource/LiteWebJarsResourceResolver
```

최신 springdoc 릴리스가 Spring Boot 3.3.4가 번들한 것보다 더 신버전 Spring
Framework 클래스를 참조하기 때문입니다(springdoc 2.8.x/2.9.x는 대략 Boot
3.4.x/3.5.x 대상). Boot 3.3.x를 쓰는 동안은 2.6.0~2.7.x 계열로 고정하세요.

### 정적 `openapi.json` 재생성

```bash
# 앱을 기동한 상태에서
curl -s http://localhost:8080/v3/api-docs \
  | python3 -c "import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=2, ensure_ascii=False)" \
  > openapi.json
```

### AWS Bedrock AgentCore Gateway 등록 시 유의점

이 스펙은 AgentCore Gateway의 OpenAPI 수집 제약(2026년 기준)에 맞춰
설계했습니다:

- **`operationId`가 곧 MCP 툴 이름**(`<target-name>___<operationId>` 형태로
  노출)이 되므로, 4개 엔드포인트 전부에 명시적이고 고유한 영어
  operationId(`createOrUpdateCustomer`, `recordPushEvent`,
  `recordClickEvent`, `getCampaignStats`)를 부여했습니다. springdoc이
  메서드 이름에서 자동 생성하게 두면 `record`처럼 겹치는 이름이 나올 수
  있습니다.
- **`securitySchemes`는 스펙에 넣지 않았습니다** — Gateway는 OpenAPI 문서의
  보안 스킴을 읽지 않고, 백엔드 인증(API 키/OAuth2, 또는 API
  Gateway·Lambda 뒤에 있을 때의 IAM/SigV4)은 **Gateway 타깃 설정에서
  별도로** 구성합니다. 스펙에 임의로 보안 스킴을 넣으면 오히려 실제 인증
  방식과 어긋나 혼란만 줍니다.
- **복잡한 스키마 합성(`oneOf`/`anyOf`/`allOf`) 없음** — 모든 요청/응답이
  평범한 Java record로 매핑되는 단순 평면 스키마입니다. 이전에는
  `Map<String, UUID>`로 응답하던 두 엔드포인트를 `RecordPushResponse`/
  `RecordClickResponse` 같은 고정 필드 DTO로 바꿔, 스키마가 "동적 키를 가진
  객체"처럼 모호하게 보이지 않도록 했습니다.
- **`servers` URL은 플레이스홀더**(`https://api.example.com`)입니다 —
  Gateway는 동적 도메인 플레이스홀더(`https://{yourDomain}/`)가 있는
  서버 URL을 지원하지 않으므로, 이 서비스를 실제로 배포한 뒤(API Gateway나
  ALB 뒤에 두는 등) `OpenApiConfig`의 `servers(...)` 값을 실제 접근
  가능한 고정 URL로 바꿔야 Gateway/Swagger에 정상 등록됩니다.
- 스펙 자체는 OpenAPI 3.0.1(3.1이 아님)로 강제 출력합니다
  (`application.yml`의 `springdoc.api-docs.version=openapi_3_0`) — Gateway는
  3.0/3.1 둘 다 지원하지만, 다른 Swagger 도구 호환성까지 고려하면 3.0이
  더 안전한 공통분모입니다.
- Gateway 등록은 스펙을 S3에 올려 그 URI를 참조하거나, 타깃 생성 API 호출
  시 JSON/YAML을 인라인으로 붙여넣는 두 방식 중 하나로 이뤄집니다 — 별도의
  "파일 업로드" API는 없습니다.

## 데이터 라이프사이클 — `pushes`/`clicks`에 90일 TTL

원본 이벤트 테이블(`pushes_local`, `clicks_local`)에 `TTL sent_at/clicked_at +
INTERVAL 90 DAY`를 적용했습니다. 사전집계 테이블(`push_stats_local`/
`click_stats_local`)은 campaign×hour 단위로 이미 훨씬 작고 리포팅 가치가
오래가므로 TTL을 두지 않았습니다 — 원본 이벤트만 정리하고 집계 결과는 계속
남기는, 실무에서 흔한 패턴입니다.

```sql
ALTER TABLE push_click.pushes_local ON CLUSTER 'cluster1' MODIFY TTL sent_at + INTERVAL 90 DAY;
ALTER TABLE push_click.clicks_local ON CLUSTER 'cluster1' MODIFY TTL clicked_at + INTERVAL 90 DAY;
```

GUIDE.md 16절은 "TTL은 만료 즉시가 아니라 병합 시점에만 평가된다"는 걸,
**배경 병합이 인위적으로 멈춰있던(`SYSTEM STOP MERGES`) 격리된 테스트
테이블**로 보여줬습니다. 이번엔 반대 사례를 실측했습니다 — 실제 운영 중인
테이블(배경 병합이 정상적으로 계속 도는)에 91일 전 타임스탬프로 백데이트된
행을 넣었더니:

```bash
# 91일 전 타임스탬프로 삽입
INSERT INTO push_click.pushes_local VALUES (generateUUIDv4(), 999999, 999999, 'ttl-expired-test', now() - INTERVAL 91 DAY, 'SENT');

# 몇 초 뒤 조회 — 이미 사라짐
SELECT count() FROM push_click.pushes_local WHERE template_id = 'ttl-expired-test';  -- => 0
```

`system.parts`를 보면 해당 파티션이 삽입 직후 곧바로 병합되며 TTL이 적용돼
`rows=0`으로 비워진 걸 확인할 수 있었습니다. **병합이 활발한 테이블에서는
TTL 정리가 수 초 내로 자동 반영되지만, 병합이 뜸한(또는 멈춘) 테이블에서는
GUIDE.md 16절처럼 수십 분~그 이상 오래된 데이터가 남아있을 수 있다** — TTL을
"보장된 삭제 시점"이 아니라 "정리 대상 표시"로 이해해야 한다는 게 두 실험을
합쳐서 얻은 결론입니다.

## 장애 내성 실측: 앱은 ClickHouse 장애에 어떻게 반응하는가

지금까지 랩 실험들은 ClickHouse 자체의 복원력(레플리카/샤드/Keeper)을
검증했습니다. 여기서는 **그 장애가 실제로 이 마이크로서비스를 거치는
클라이언트에게 어떻게 보이는지**를 초 단위로 실측했습니다 — 앱을 로컬로
띄우고 1초 간격으로 `GET /api/campaigns/{id}/stats`와
`POST /api/pushes`를 계속 호출하면서 장애를 주입했습니다.

### 실험 A: 레플리카 파드 강제 삭제 (경미한 장애)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse delete pod chi-chi-cluster1-0-1-0
```

**결과**: 파드가 삭제되고 16초 만에 재기동되는 전체 구간(60초, 120회 호출)
동안 **에러 0건**. `Distributed` 테이블이 죽은 레플리카를 자동으로 우회하는
동작이 애플리케이션 레벨에서 완전히 투명했습니다 — 클라이언트는 뒤에서
레플리카 하나가 죽었다 살아난 것을 전혀 알아챌 수 없습니다.

### 실험 A 재현 — 그리고 "항상 투명하지는 않다"는 반례 발견

이 결과가 우연이 아닌지 확인하려고 다시 실행하다가, **로컬 개발 환경의
숨은 변수**를 하나 발견했습니다: 로컬 `kubectl port-forward`
(`svc/clickhouse-chi`)는 시작할 때 서비스 뒤의 12개 파드 중 **딱 하나에
고정**됩니다(`SELECT hostName()`으로 확인 가능). 지금까지 실험은 전부
이 고정된 파드가 아닌 **다른** 레플리카를 죽였기 때문에 매번 투명하게
넘어갔던 것입니다.

| 재현 | 죽인 파드 | port-forward가 물려있던 파드 | 결과 |
|---|---|---|---|
| 재현 #1 | `chi-chi-cluster1-1-0-0` (다른 샤드) | `chi-chi-cluster1-0-0-0` | 45회 전부 성공, 에러 0건 (재확인됨) |
| 재현 #2 | **`chi-chi-cluster1-0-0-0`(port-forward가 물려있던 바로 그 파드)** | 동일 | **파드 재기동 후 40초 넘게 계속 연결 실패**(`000`, TCP 연결 자체가 거부됨) |

재현 #2에서 파드는 16초 만에 정상적으로 재기동됐지만, 요청은 계속 실패했습니다.
확인해보니 원인은 ClickHouse나 이 앱이 아니라 **`kubectl port-forward`
프로세스 자체가 죽어 있었던 것**(`ps aux`에서 완전히 사라짐)이었습니다 —
port-forward는 터널을 처음 만들 때 고정한 파드가 사라지면 **다른 건강한
파드로 자동 전환하지 않고 그냥 죽습니다**. 진짜 Kubernetes Service(kube-proxy
경유)는 죽은 엔드포인트를 자동으로 빼고 다른 파드로 라우팅하지만,
`kubectl port-forward`는 그런 재라우팅을 하지 않는 별개의 메커니즘입니다.
port-forward를 수동으로 재기동하자(새 대상 파드로 재연결) 앱은 즉시
정상으로 돌아왔습니다 — **애플리케이션이나 HikariCP 자체의 결함이 아니라,
로컬 테스트 방식의 구조적 한계**였습니다.

**결론**: "레플리카 삭제는 항상 투명하다"는 원래 결론은 **ClickHouse의
Distributed 라우팅 자체**에 대해서는 여전히 유효합니다(재현 #1이 이를
다시 확인). 하지만 이 랩처럼 `kubectl port-forward`로 로컬에서 접속하는
구성에서는, **port-forward가 우연히 고정된 그 파드가 죽으면** 실제
운영 환경(진짜 Service를 통한 배포)에서는 일어나지 않을 별도의 장애가
발생합니다. 이건 앱을 실제로 클러스터 안에 배포(`application-incluster.yml`
프로파일, 진짜 Service 경유)하면 애초에 존재하지 않는 문제입니다 — 로컬
개발 방식이 만들어낸 인위적인 단일 장애점(SPOF)이었다는 걸 명확히 알아야
합니다.

### 실험 B: Keeper 쿼럼 상실 (심각한 장애) — 가장 놀라웠던 발견

```bash
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chk-chk-keeper-0-1 chk-chk-keeper-0-2 --replicas=0
```

| 시각(경과) | `GET stats` | `POST pushes` | `/actuator/health` | 실제 저장된 행 수 |
|---|---|---|---|---|
| 쿼럼 상실 직후 | 200 | **202** | UP → **DOWN**(수 초 내) | 77 |
| +10초 (여전히 쿼럼 없음) | 200 | **202** | DOWN | **77 (변화 없음!)** |
| 쿼럼 복구 시도 (+81초) | 200 | 202 | DOWN | - |
| +15초 후 | 200 | 202 | **UP**으로 복귀 | **89 (자동 반영됨)** |

**가장 중요한 발견**: `POST /api/pushes`는 Keeper 쿼럼이 없는 내내 계속
**`202 Accepted`를 정상 응답**했습니다 — 클라이언트 입장에선 아무 문제도
없어 보입니다. 하지만 실제로는 `async_insert=1`이 로컬 큐에만 쌓아두고
있었을 뿐, **10초 동안 응답은 77번 넘게 202를 반환했는데 실제 저장된 행은
단 하나도 늘지 않았습니다.** `GET stats` 조회는 문제없이 계속 성공했는데,
이는 읽기가 Keeper를 필요로 하지 않기 때문입니다(Keeper는 오직 쓰기
합의(coordination)에만 관여).

이 상태에서 **유일하게 정확한 신호는 HTTP 상태 코드가 아니라
`/actuator/health`였습니다** — `clickHouseCluster` 컴포넌트가
`keeperConnected: false`와 함께 `readonlyTables`에 **테이블 5개 전부**를
정확히 나열하며 즉시 DOWN(503)으로 전환됐습니다. 만약 모니터링이 앱의 HTTP
응답 코드만 보고 있었다면, 이 장애는 **완전히 눈에 띄지 않았을 것**입니다.

쿼럼이 복구되자(9초 만에 3/3 정상), 앱의 헬스는 약 15초 뒤 자동으로 UP으로
돌아왔고, 그동안 202로 "성공" 응답했지만 큐에 쌓여있던 쓰기들이 **사람의
개입 없이 전부 자동으로 반영**됐습니다(77 → 89, 데이터 유실 없음, 지연만
있었음).

### 재현성 검증 — 우연이 아닌지 대조군으로 확인

이 현상이 1회성 우연이 아닌지 확인하기 위해, **음성 대조군**(Keeper 1개만
다운, 쿼럼은 2/3로 유지)과 **양성 재현**(쿼럼 상실 재시도)을 추가로
실행했습니다.

| 시나리오 | Keeper | 쓰기 응답 | 실제 저장 | 헬스 |
|---|---|---|---|---|
| 음성 대조군 (쿼럼 유지) | 2/3 | 202 | **즉시 반영**(151→156, +5) | UP |
| 양성 재현 #1 (쿼럼 상실) | 1/3 | 202 | **동결**(77→77) | DOWN |
| 양성 재현 #2 (쿼럼 상실) | 1/3 | 202 | **동결**(156→156) | DOWN |
| 복구 (양쪽 다) | 3/3 | 202 | **자동 반영**(→89, →161) | UP |

**Keeper 1개만 다운된(쿼럼 유지) 대조군에서는 문제가 전혀 재현되지 않고
즉시 정상 반영**됐습니다 — 이걸로 "쓰기가 숨겨지는 현상"이 Keeper가
불안정해서가 아니라 **정확히 쿼럼 상실 그 자체** 때문임을 확인했습니다.
쿼럼 상실은 두 번 다 정확히 같은 패턴(202 응답 + 저장 동결 +
`keeperConnected: false` + 자동 복구)을 보였습니다.

다만 완전히 동일하지는 않았던 부분도 정직하게 남겨둡니다: 첫 실험에서는
`readonlyTables`에 5개 테이블이 전부 표시됐지만, 두 번째 재현에서는 이
필드가 비어 있었습니다 — `keeperConnected` 플래그는 두 번 다 즉시
정확했지만, `system.replicas.is_readonly`가 실제로 갱신되는 타이밍은
실행마다 약간 다를 수 있어 보입니다. **`keeperConnected`가 이 헬스체크의
가장 신뢰할 수 있는 신호이고, `readonlyTables`는 보조 신호로 취급해야
합니다.**

### 결론

- **읽기 경로는 Keeper 장애에 영향받지 않는다** — 조회 API는 계속 정상
  응답한다.
- **쓰기 경로는 `async_insert`로 인해 장애를 "숨긴다"** — HTTP 202는
  "받았다"는 뜻이지 "저장했다"는 뜻이 아니다. 이 갭이 벌어지는 동안은
  클라이언트 관점에서 완전히 정상으로 보인다.
- **`/actuator/health`(ClickHouseClusterHealthIndicator)가 유일하게 이
  상황을 정확히 잡아낸다** — 프로덕션에서는 이 서비스의 알람을 반드시
  HTTP 200/202 여부가 아니라 이 헬스 엔드포인트 기준으로 걸어야 한다.
- 데이터는 결국 유실 없이 자동 반영됐지만, 그 사이 "저장됐다고 응답받은
  데이터가 실제로는 아직 없는" 윈도우가 존재한다는 걸 이 서비스를 호출하는
  쪽(특히 즉시 조회하는 로직)이 인지하고 있어야 한다.

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
  안정성/버퍼링 면에서 유리합니다 — 실제로 배포해 검증한 내용(poison pill
  처리, 컨슈머 그룹 변경 시 재처리/중복 이슈 등)은
  [`KAFKA-INTEGRATION.md`](../../KAFKA-INTEGRATION.md) 참고.
- **`incluster` 프로파일로 클러스터 안에 배포**: `application-incluster.yml`을
  참고해 이 서비스 자체를 CHI와 같은 네임스페이스의 Deployment로 배포하면,
  이 문서의 "알려진 이슈 4번"(포트 충돌)은 애초에 발생하지 않습니다.
