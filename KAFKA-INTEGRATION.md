# ClickHouse Kafka 테이블 엔진 가이드

`apps/push-click-service/README.md`의 "다음 확장 아이디어"에 "발송/클릭
이벤트량이 커지면 Kafka로 발행하고 `Kafka` 테이블 엔진 + MV로 소비하는 구조가
유리하다"라고만 적어두고 실제로 검증한 적은 없었습니다. 이 문서는 그 아이디어를
**실제로 배포해 검증한** 결과입니다.

## 인프라: 왜 Kafka 대신 Redpanda인가

실제 Apache Kafka는 ZooKeeper(또는 KRaft) 포함 최소 구성만으로도 이 랩의
Colima VM(6vCPU/16GB, 이미 12개 CH 파드 + Keeper 3노드 + 오퍼레이터 +
Prometheus/Grafana가 떠 있음)에 부담이 큽니다. **Redpanda**는 Kafka 와이어
프로토콜과 100% 호환되면서 단일 바이너리·ZooKeeper 불필요라 ClickHouse의
`Kafka` 엔진 입장에서는 완전히 동일하게 동작합니다.

```yaml
# manifests/kafka/redpanda.yaml (요약)
containers:
  - name: redpanda
    image: docker.redpanda.com/redpandadata/redpanda:v24.2.18
    args:
      - redpanda
      - start
      - --smp=1
      - --memory=900M       # 아래 참고
      - --overprovisioned
      - --node-id=0
      - --kafka-addr=PLAINTEXT://0.0.0.0:9092
      - --advertise-kafka-addr=PLAINTEXT://redpanda.clickhouse.svc.cluster.local:9092
    resources:
      limits:
        memory: "1300Mi"
```

> **겪은 함정**: 처음엔 `--memory=1G` + 파드 `limits.memory: 1Gi`로 배포했더니
> `Could not initialize seastar: insufficient physical memory: needed
> 1073741824 available 1027604480`로 크래시루프에 빠졌습니다. Redpanda의
> Seastar 런타임이 요청한 메모리보다 실제로 조금 더 여유가 필요합니다 —
> `--memory` 플래그 값보다 파드 limit을 400MB 정도 넉넉히 잡아야 합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/kafka/redpanda.yaml
kubectl --context kind-clickhouse-lab -n clickhouse exec deploy/redpanda -- \
  rpk topic create push_events --brokers localhost:9092
```

## 표준 패턴: Kafka 엔진 테이블은 절대 직접 쿼리하지 않는다

ClickHouse의 `Kafka` 엔진은 그 자체로 저장소가 아니라 **컨슈머를 감싼 뷰**에
가깝습니다. 항상 3개 오브젝트 세트로 씁니다:

```sql
-- 1. Kafka 엔진 테이블: 컨슈머 그 자체. 조회용이 아니다.
CREATE TABLE kafka_demo.events_queue
(
    event_id UInt64,
    event_type String,
    payload String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda.clickhouse.svc.cluster.local:9092',
    kafka_topic_list = 'push_events',
    kafka_group_name = 'clickhouse_consumer_group',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;

-- 2. 실제 데이터가 쌓이는 테이블
CREATE TABLE kafka_demo.events
(
    event_id UInt64,
    event_type String,
    payload String,
    consumed_at DateTime DEFAULT now()
)
ENGINE = MergeTree ORDER BY event_id;

-- 3. 1을 읽어 2에 쓰는 Materialized View — 이게 있어야 실제로 소비가 일어난다
CREATE MATERIALIZED VIEW kafka_demo.events_mv TO kafka_demo.events AS
SELECT event_id, event_type, payload FROM kafka_demo.events_queue;
```

메시지를 발행하면 몇 초 안에 `events` 테이블에 쌓입니다:

```bash
echo '{"event_id": 1, "event_type": "push_sent", "payload": "hello-from-kafka"}' | \
  kubectl exec -i deploy/redpanda -n clickhouse -- rpk topic produce push_events --brokers localhost:9092
```

### "직접 쿼리하면 안 된다"는 이제 경고가 아니라 하드 블록

옛 문서/블로그에는 "Kafka 엔진 테이블을 직접 SELECT하면 큐에서 데이터가
사라지니 주의하라"는 식으로 적혀 있는데, 우리가 쓴 버전(26.9)은 **아예 막혀
있습니다**:

```
$ SELECT * FROM kafka_demo.events_queue;
Code: 620. DB::Exception: Direct select is not allowed. To enable use
setting `stream_like_engine_allow_direct_select`, but be aware that
usually the read data is removed from the queue.
```

## 장애 실험: "Poison Pill" — 메시지 하나가 파이프라인 전체를 멈춘다

이 랩의 방법론대로, 정상 메시지 사이에 **깨진 JSON**을 하나 끼워 넣었습니다:

```bash
echo 'this is not valid json at all' | rpk topic produce push_events ...
echo '{"event_id": 3, ...}' | rpk topic produce push_events ...   # 이어서 정상 메시지
```

**결과**: `event_id=3`(정상 메시지)이 **영원히 도착하지 않았습니다.**
`system.kafka_consumers`로 원인을 확인:

```sql
SELECT assignments.current_offset, exceptions.text, exceptions.time
FROM system.kafka_consumers WHERE table = 'events_queue' FORMAT Vertical
```

```
assignments.current_offset: [-1001]   -- 정상 진행이 안 되고 있다는 신호
exceptions.text: ['Cannot parse input: expected \'{\' before: ... (at row 1):
  while parsing Kafka message (topic: push_events, partition: 0, offset: 2)']
exceptions.time: ['02:16:43','02:16:45','02:16:47','02:16:49','02:16:51', ...]
```

**offset 2(그 깨진 메시지)에서 2초 간격으로 계속 같은 파싱 에러를 내며
무한 재시도**하고 있었습니다 — 죽지도, 건너뛰지도 않고 그 자리에 멈춰서
뒤에 온 정상 메시지까지 전부 막아버리는 전형적인 "poison pill" 현상입니다.

### 해결: `kafka_skip_broken_messages`

```sql
ALTER TABLE kafka_demo.events_queue ...  -- Kafka 엔진 설정은 라이브 ALTER 불가, DROP 후 재생성 필요
```

```sql
CREATE TABLE kafka_demo.events_queue (...)
ENGINE = Kafka
SETTINGS
    ...,
    kafka_skip_broken_messages = 10;  -- 파싱 실패 메시지를 최대 10개까지 건너뛰고 계속 진행
```

재생성 후 `event_id=3`이 정상적으로 도착했습니다. **기본값(0, 하나도 건너뛰지
않음)으로 운영하면, 잘못된 형식의 메시지 단 하나가 그 파티션의 전체 소비를
영구적으로 멈출 수 있다**는 게 이번 실험의 핵심 교훈입니다 — 프로덕션에서는
반드시 이 값을 명시적으로 설정하고, 건너뛴 메시지를 별도로 로깅/알람하는
방안(예: `kafka_handle_error_mode = 'stream'`로 에러 메시지를 별도 스트림에
남기는 옵션)까지 함께 검토해야 합니다.

## 뜻밖의 부작용: 컨슈머 그룹을 바꾸면 처음부터 재처리되고, 중복은 자동으로 막히지 않는다

위 재생성 시 `kafka_group_name`을 새 이름(`..._v2`)으로 바꿨더니, Kafka의
기본 동작(`auto.offset.reset`)에 따라 **토픽 맨 처음부터 재소비**됐습니다.
결과:

```
event_id=1  hello-from-kafka   (2026-09-11 02:16:12)  ← 원래 소비된 것
event_id=1  hello-from-kafka   (2026-09-11 02:17:19)  ← 재소비로 중복!
event_id=2  second-message     (2026-09-11 02:16:23)
event_id=2  second-message     (2026-09-11 02:17:19)  ← 역시 중복
event_id=3  after-bad-message  (2026-09-11 02:17:19)  ← 이번에 처음 성공
```

`MergeTree`는 기본적으로 **중복 제거를 전혀 하지 않습니다.** 컨슈머 그룹
이름을 바꾸는 건 운영 중 흔히 일어나는 일(설정 변경, 테이블 재생성, 오퍼레이터
업그레이드 등)이므로, 실제 운영에서는 대상 테이블을 `ReplacingMergeTree`
(또는 애플리케이션 레벨 idempotency key)로 설계해 이런 재처리가 중복 데이터로
이어지지 않게 해야 합니다 — 우리 `push_click.customers_local`이 이미
`ReplacingMergeTree`를 쓰는 이유이기도 합니다(GUIDE.md/앱 스키마 참고).

## `system.kafka_consumers`로 확인할 수 있는 것들

이번 실험에서 실제로 유용했던 컬럼들:

| 컬럼 | 용도 |
|---|---|
| `assignments.current_offset` | 정상 진행 중인지, 멈춰있는지(`-1001` 같은 비정상 값) |
| `exceptions.text` / `exceptions.time` | 최근 에러 이력과 발생 시각 — poison pill 진단의 핵심 |
| `assignments.topic` / `partition_id` | 이 컨슈머가 실제로 어느 토픽/파티션을 맡고 있는지 |

## 부하 테스트: 컨슈머를 늘리면 실제로 빨라질까

`kafka_num_consumers`를 늘려서 파티션 수만큼 병렬로 소비하게 하면 처리량이 오를
것 같지만, GUIDE.md 15절에서 `max_parallel_replicas`가 오히려 역효과였던 것과
같은 이유(이 랩은 6vCPU를 12개 CH 파드 + Keeper + Redpanda + 모니터링이 전부
공유)로 여기서도 별 효과가 없을 거라 예상하고 실제로 측정해봤습니다.

### 준비: 4파티션 토픽 + 4-컨슈머 Kafka 엔진 테이블

```bash
rpk topic create load_test_events -p 4 --brokers localhost:9092
```

```sql
CREATE TABLE kafka_demo.load_test_queue
(
    event_id UInt64,
    event_type String,
    payload String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda.clickhouse.svc.cluster.local:9092',
    kafka_topic_list = 'load_test_events',
    kafka_group_name = 'load_test_group_4c_v2',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4,
    kafka_skip_broken_messages = 10;

CREATE TABLE kafka_demo.load_test_events
(
    event_id UInt64,
    event_type String,
    payload String,
    consumed_at DateTime64(3) DEFAULT now64(3)
)
ENGINE = MergeTree ORDER BY event_id;

CREATE MATERIALIZED VIEW kafka_demo.load_test_mv TO kafka_demo.load_test_events AS
SELECT event_id, event_type, payload FROM kafka_demo.load_test_queue;
```

메시지 5만 건짜리 JSON 파일을 만들어 `rpk topic produce`로 발행했습니다. 프로듀서
자체는 병목이 전혀 아니었습니다 — 5만 건을 로컬 단일 노드 Redpanda에 발행하는 데
약 0.2초(**초당 약 25만 건**)밖에 걸리지 않았습니다.

### 겪은 함정 1: `DEFAULT now64(3)`는 행 단위가 아니라 블록 단위로 평가된다

처음엔 `consumed_at`(`DEFAULT now64(3)`) 컬럼으로 행별 도착 시각을 재서 처리량을
계산하려 했습니다. 그런데 첫 배치를 확인해보니 5만 건 전부의 `consumed_at`이
**완전히 동일한 값**이었습니다(`min(consumed_at) == max(consumed_at)`). Kafka
엔진 MV는 한 번에 하나의 블록(폴링 주기당 쌓인 메시지 묶음)을 통째로 INSERT하고,
`now64()` 같은 비결정적 기본값 표현식은 **그 INSERT 블록 전체에 대해 한 번만
평가**되기 때문입니다 — 행마다 다시 평가되지 않습니다. 그래서 이 컬럼은 "이
배치가 대략 언제 들어왔는지"만 알려줄 뿐, 개별 행의 처리량/지연시간 측정에는
쓸 수 없었습니다. 결국 애플리케이션 쪽 wall-clock(bash `date` 기반 폴링)으로
측정 방식을 바꿨습니다.

### 겪은 함정 2: 폴링 루프를 늦게 시작하면 타이밍을 놓친다

Kafka 엔진 테이블은 MV가 생성되는 순간부터 바로 컨슈밍을 시작합니다. DDL 실행과
폴링 루프 시작 사이에 몇 초라도 간격(예: 그 사이에 `rpk topic describe`처럼 다른
명령을 실행)이 생기면, 처음 폴링했을 때 이미 100% 완료된 상태만 보게 되어 아무런
타이밍 곡선도 얻을 수 없습니다. 실제로 첫 4-컨슈머 측정 시도가 이렇게 실패했습니다
— DROP/CREATE를 한 명령으로, 폴링 시작을 별도의 다음 명령으로 나눠 실행했더니
그 사이 이미 10만 건이 전부 소비되어버렸습니다. **DDL 실행과 0.15초 간격의 타이트한
폴링 시작을 하나의 명령 안에** 묶어야 유효한 곡선을 얻을 수 있었습니다.

### 측정 결과

| 구성 | 소비한 메시지 | 소요 시간 | 처리량 |
|---|---|---|---|
| `kafka_num_consumers=1` | 50,000건 | 3.95초 | ≈12,658건/초 |
| `kafka_num_consumers=4` (파티션 4개와 일치, 새 컨슈머 그룹으로 토픽 전체 재소비) | 100,000건 | 8.19초 | ≈12,210건/초 |

4-컨슈머 측정은 메시지 수가 달라(10만 건, 새 컨슈머 그룹이라 토픽에 쌓인 전체를
처음부터 재소비) 절대 시간으로는 직접 비교할 수 없지만, 건당 처리량으로 정규화하면
**12,658건/초 vs 12,210건/초로 사실상 동일**(오차 범위 4% 이내)합니다.

**결론: 이 환경에서는 `kafka_num_consumers`를 늘려도 처리량이 개선되지 않습니다.**
GUIDE.md 15절의 `max_parallel_replicas` 실험과 정확히 같은 원인입니다 — 컨슈머
스레드를 4개로 늘려도 그것들이 나눠 쓸 물리 CPU 코어 자체가 늘어나는 게 아니라,
이미 다른 12개 CH 파드·Keeper·Redpanda·모니터링 스택과 공유 중인 6개 코어를
서로 더 잘게 나눠 경쟁할 뿐이기 때문입니다. `kafka_num_consumers`는 **CPU 코어가
실제로 여유 있고, 컨슈머당 처리량이 네트워크/디스크가 아니라 CPU 파싱 비용에
막혀 있는 환경**에서만 의미가 있습니다 — 파티션 수를 늘리는 것도 마찬가지로,
컨슈머를 늘릴 여유 코어가 없다면 파티션만 늘리는 건 효과가 없습니다.

### 정리에 쓴 명령

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- \
  clickhouse-client --multiquery -q "
    DROP TABLE kafka_demo.load_test_mv;
    DROP TABLE kafka_demo.load_test_queue;
    DROP TABLE kafka_demo.load_test_events;"
kubectl --context kind-clickhouse-lab -n clickhouse exec deploy/redpanda -- \
  rpk topic delete load_test_events --brokers localhost:9092
```

## push-click-service에 적용한다면

`apps/push-click-service`의 발송/클릭 이벤트를 지금처럼 HTTP INSERT 대신
Kafka로 발행하는 구조로 바꾼다면, 이번 실험에서 확인한 두 가지를 반드시
설계에 반영해야 합니다:
1. `kafka_skip_broken_messages`를 명시적으로 설정(앱이 잘못된 JSON을 보낼
   가능성은 항상 있음).
2. `pushes_local`/`clicks_local`처럼 자연스러운 유니크 키(`send_id`,
   `click_id`)가 있는 테이블이라도, 컨슈머 그룹 변경 등으로 인한 재처리
   가능성을 고려해 멱등성 처리(애플리케이션 레벨 dedup, 또는
   `ReplacingMergeTree` + 주기적 `OPTIMIZE`/조회 시 `FINAL`)를 함께
   설계해야 함.

## 정리

이 실험은 `push_click`과 격리된 `kafka_demo` 데이터베이스에서 진행해 기존
서비스 스키마에는 영향이 없습니다. 정리하려면:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- \
  clickhouse-client -q "DROP DATABASE kafka_demo"
kubectl --context kind-clickhouse-lab delete -f manifests/kafka/redpanda.yaml
```

이 랩을 계속 쓸 계획이라면 Redpanda는 Prometheus/Grafana처럼 그대로 띄워둬도
무방합니다(리소스 요청 250m CPU/768Mi 메모리로 가볍습니다).
