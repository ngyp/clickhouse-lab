# ClickHouse 툴 콜링 가이드

"ClickHouse를 LLM 에이전트가 툴로 호출할 수 있는가?"에 대한 답은 **네, 그것도
두 가지 서로 다른 경로로** 가능합니다. 이 문서는 두 경로를 비교하고, 그중
하나(`altinity-mcp`)는 이 저장소의 랩 클러스터에 **실제로 연결해 검증한**
결과를 근거로 정리했습니다.

## 두 가지 경로

| | **경로 A: ClickHouse를 직접 MCP로 열기** | **경로 B: 앱을 경유 (이미 구현함)** |
|---|---|---|
| 무엇을 노출하는가 | ClickHouse 자체 (임의 SQL, 또는 뷰 기반 큐레이션 툴) | `apps/push-click-service`가 제공하는 **의도적으로 좁은** REST API |
| 에이전트가 할 수 있는 일 | 스키마 탐색, 임의 SELECT, (설정에 따라) 쓰기까지 | `createOrUpdateCustomer`/`recordPushEvent`/`recordClickEvent`/`getCampaignStats` 4개 딱 정해진 동작만 |
| 안전 모델 | MCP 서버의 SQL 문 필터 + ClickHouse GRANT (이중) | 애초에 SQL을 노출하지 않음 — API 계약 자체가 안전 경계 |
| 적합한 상황 | 탐색적 분석, 운영자의 임시 조회, 데이터 사이언티스트 워크플로 | 정해진 업무 흐름을 에이전트에 맡기는 프로덕션 시나리오 |
| 이 저장소의 관련 문서 | 이 문서 | `PRODUCTION-AWS.md` 12절, `apps/push-click-service/openapi.json` |

**두 경로는 배타적이지 않습니다.** 같은 클러스터에 대해 운영자는 경로 A로
탐색하고, 프로덕션 에이전트 워크로드는 경로 B의 좁은 계약을 쓰는 식으로
공존시킬 수 있습니다.

## 경로 A: MCP 서버 두 종류

| | **`ClickHouse/mcp-clickhouse`** (공식) | **`Altinity/altinity-mcp`** |
|---|---|---|
| 제공 툴 | `run_query`, `list_databases`, `list_tables`, `run_chdb_select_query` | `execute_query`(+ read-only가 아니면 `write_query`) + **뷰 기반 동적 툴** |
| 기본 자세 | **읽기전용**(`readonly=1`), 쓰기는 opt-in | 기본은 읽기+쓰기, `--read-only`로 잠가야 함 |
| 전송 | stdio / Streamable HTTP / SSE(구식) | stdio / HTTP / SSE, **OpenAPI 호환 엔드포인트도 지원** |
| 인증 | 환경변수, TLS/X.509 | OAuth2/OIDC, JWT, JWE, mTLS (더 풍부) |
| 배포 | pip/uv/Docker | Go 바이너리, Docker, **Helm 차트** |
| Self-hosted 지원 | O | O |
| 이 문서에서의 검증 상태 | 리서치만(라이브 테스트 안 함) | **아래에 실제 연결·툴콜 결과 기록** |

`altinity-mcp`를 먼저 시도한 이유: 이 랩이 이미 Altinity 오퍼레이터
생태계이고, Helm 차트가 있어 나중에 클러스터 안에 배포하기도 자연스럽기
때문입니다.

## `altinity-mcp` 실제 연결 검증

### 설치 및 연결 테스트

```bash
go install github.com/altinity/altinity-mcp/cmd/altinity-mcp@latest

# 우리 랩의 최소 권한 앱 계정(push_click_app)으로 연결 테스트
$(go env GOPATH)/bin/altinity-mcp test-connection \
  --clickhouse-host 127.0.0.1 --clickhouse-port 18123 --clickhouse-protocol http \
  --clickhouse-database push_click \
  --clickhouse-username push_click_app --clickhouse-password '<password>' \
  --read-only
```

**결과**: `table_count=13` — `push_click` 스키마의 테이블/뷰/MV 13개(`customers`,
`pushes`, `clicks`, `campaign_realtime_stats` 등)를 정확히 인식했습니다.

### MCP 프로토콜 (JSON-RPC over HTTP)로 실제 툴 콜

```bash
$(go env GOPATH)/bin/altinity-mcp --transport http --address 127.0.0.1 --port 8090 \
  --clickhouse-host 127.0.0.1 --clickhouse-port 18123 --clickhouse-protocol http \
  --clickhouse-database push_click \
  --clickhouse-username push_click_app --clickhouse-password '<password>' \
  --read-only
```

`initialize` → `tools/list` → `tools/call`(`execute_query`)까지 표준 MCP
핸드셰이크가 그대로 동작했고, 우리 `campaign_realtime_stats` 뷰를 조회한
실제 응답:

```json
{
  "columns": ["campaign_id", "hour", "sent_count", "click_count", "ctr"],
  "types": ["UInt64", "DateTime", "UInt64", "UInt64", "Float64"],
  "rows": [[9001, "2026-09-09T09:00:00Z", 240, 4, 0.0166...]],
  "count": 1
}
```

LLM이 바로 소비할 수 있는 컬럼명/타입/행 구조로 정리되어 나옵니다 — 원본
ClickHouse HTTP 인터페이스의 TSV/JSONEachRow보다 에이전트 친화적입니다.

### 안전장치 이중 검증 (핵심)

`--read-only` 모드에서 파괴적 쿼리를 시도하면 **MCP 서버 레벨**에서 먼저
막힙니다:

```
DROP TABLE push_click.customers_local
→ "execute_query only accepts read-only statements (...). Use write_query for write operations."

INSERT INTO push_click.pushes_local VALUES (...)
→ (동일하게 차단)
```

여기서 멈추지 않고, **MCP 레이어를 완전히 우회**해 같은 계정(`push_click_app`)
으로 `clickhouse-client`에서 직접 같은 DROP을 시도했습니다:

```
DB::Exception: push_click_app: Not enough privileges.
To execute this query, it's necessary to have the grant DROP TABLE ON push_click.customers_local. (ACCESS_DENIED)
```

**두 겹의 방어가 독립적으로 작동함을 확인했습니다** — MCP 서버의 SQL 문
필터(1차)와 ClickHouse 계정 자체의 GRANT(2차, 진짜 보안 경계). 공식
`mcp-clickhouse`도 문서에서 스스로 "SQL 문 탐지는 보안 경계가 아니다"라고
명시합니다 — **어떤 MCP 서버를 쓰든, 진짜 안전장치는 결국 최소 권한
ClickHouse 계정**입니다(`PRODUCTION.md` 10절과 동일한 결론). 이번 테스트에
쓴 `push_click_app`는 GUIDE.md/AUDIT.md 작업에서 이미 만들어둔 최소 권한
계정을 그대로 재사용했습니다:

```
GRANT SELECT, INSERT ON push_click.* TO push_click_app
GRANT SELECT ON system.mutations TO push_click_app
GRANT SELECT ON system.parts TO push_click_app
GRANT SELECT ON system.replicas TO push_click_app
GRANT SELECT ON system.zookeeper_connection TO push_click_app
```

이 계정은 `system.numbers`조차 못 읽습니다(`SELECT ON system.numbers` 권한이
없어 거부됨) — 딱 필요한 만큼만 허용된 좋은 예시입니다.

### 결과 행 수 제한(기본 500행)도 실측

```
SELECT number FROM numbers(2000)
→ count: 500, truncated: {"reason":"max_result_rows","limit":500,"returned_rows":500,"returned_bytes_approx":2890}
```

단순히 잘라내는 게 아니라, **왜 잘렸는지를 구조화된 필드로 에이전트에게
알려줍니다** — LLM이 "결과가 불완전하다"는 걸 인지하고 쿼리를 좁혀 재시도할
수 있게 하는 설계입니다.

### 뷰 기반 동적 툴 — SQL만으로 업무 특화 툴 만들기

`execute_query`라는 범용 SQL 실행 툴 대신, 설정 파일로 뷰 하나를 업무
의미가 담긴 전용 툴로 노출할 수 있습니다:

```yaml
clickhouse:
  host: "127.0.0.1"
  port: 18123
  protocol: "http"
  database: "push_click"
  username: "push_click_app"
  password: "<password>"
  read_only: true
server:
  tools:  # 구버전 필드명은 dynamic_tools (지금은 경고와 함께 여전히 동작)
    - name: "get_campaign_ctr_stats"
      regexp: "push_click\\.campaign_realtime_stats"
```

`tools/list`에 `execute_query`가 아니라 **`get_campaign_ctr_stats`**라는
이름의 전용 툴이 나타나고, 호출하면 그 뷰의 결과를 그대로 반환합니다 — 우리가
`apps/push-click-service`에서 손으로 작성한 `@Operation(operationId=...)`
패턴(경로 B)과 정확히 같은 발상을, **자바 코드 없이 SQL 뷰 + YAML 설정만으로**
달성하는 셈입니다.

## Claude Code에 직접 등록해서 써보기 (로컬 개발용)

프로덕션 에이전트가 아니라, 지금처럼 랩을 다루는 동안 직접 SQL 툴 콜링을
쓰고 싶다면 가장 가벼운 방법입니다:

```bash
claude mcp add altinity-clickhouse -- \
  $(go env GOPATH)/bin/altinity-mcp \
  --clickhouse-host 127.0.0.1 --clickhouse-port 18123 --clickhouse-protocol http \
  --clickhouse-database push_click \
  --clickhouse-username push_click_app --clickhouse-password '<password>' \
  --read-only
```

세션을 재시작하면 `execute_query`(또는 위에서 설정한 동적 툴)가 Claude Code의
툴 목록에 나타납니다. **AWS Bedrock AgentCore Gateway로 프로덕션에 등록하는
것과는 완전히 별개**의, 로컬 개발/운영 편의 시나리오입니다.

## 경로 A를 AWS Bedrock AgentCore Gateway로 프로덕션에 올리려면

`PRODUCTION-AWS.md` 12절에서 다룬 AgentCore Gateway는 OpenAPI 타깃뿐 아니라
**MCP 서버 타깃**도 직접 지원합니다 — `altinity-mcp`/`mcp-clickhouse`를
ECS·Lambda·AgentCore Runtime 등에 이미 떠 있는 상태로 올려두고, 그 URL을
Gateway 타깃으로 등록하면 됩니다(Gateway가 MCP 서버를 대신 호스팅해주지는
않습니다). 인증은 Gateway 타깃 설정에서 별도로(OAuth/API 키/IAM) 구성합니다
— 이 부분은 OpenAPI 타깃(경로 B)과 동일한 원칙입니다.

## 선택 기준 요약

- **탐색적 분석·운영 디버깅·데이터 사이언티스트 워크플로** → 경로 A
  (`altinity-mcp`), 반드시 최소 권한 전용 계정으로
- **정해진 업무를 에이전트에 안정적으로 맡기는 프로덕션** → 경로 B(이미 구현한
  `apps/push-click-service` + `openapi.json` + AgentCore Gateway)
- 경로 A를 쓰더라도 **MCP 서버의 SQL 문 필터를 유일한 방어선으로 믿지 말 것**
  — 반드시 ClickHouse 계정 자체의 GRANT로 진짜 경계를 세우세요.
