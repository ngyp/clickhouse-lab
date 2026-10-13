# ClickHouse 아키텍처 기술 리포트: 실시간 로그 집계가 빠른 이유

- 작성일: 2026-10-13
- 대상: ClickHouse(MergeTree 계열 엔진)로 로그/이벤트 분석 시스템을 설계·운영하려는 엔지니어
- 기준 버전: 이 랩에서 사용한 ClickHouse 26.9.1 (일부 설정 기본값은 버전에 따라 다를 수 있음)

## 요약

로그 데이터는 **추가만 되고 수정되지 않으며**, 조회는 **많은 행의 일부 컬럼을 범위로
스캔해 집계**하는 패턴을 가집니다. ClickHouse는 이 패턴에 맞춰 세 계층을 설계했습니다.

1. **컬럼 지향 저장** — 필요한 컬럼만 읽고, 연속 배열 덕분에 SIMD·CPU 캐시를 최대로
   활용하며, 같은 타입·비슷한 값이 모여 있어 압축률이 높습니다.
2. **불변 파트(Immutable Parts)** — INSERT는 정렬·압축된 새 파트를 쓰는 것으로 끝나고,
   정리는 백그라운드 머지가 맡아 쓰기 경로가 매우 짧습니다.
3. **그래뉼과 희소 인덱스(Sparse Index)** — 8,192행 단위로 읽고 건너뛰며, 작은 인덱스가
   항상 메모리에 상주합니다. 성능은 정렬 키·카디널리티·파티션 설계에 크게 좌우됩니다.

마지막으로 공개 벤치마크(ClickBench)와 이 레포에서 직접 측정한 결과를 통해 이 특징들이
실제로 무엇을 측정하고 무엇을 측정하지 않는지 정리합니다.

## 목차

1. [Columnar Storage](#1-columnar-storage-컬럼-지향-저장)
   - 1-1. Row-oriented vs Column-oriented
   - 1-2. SIMD와 CPU 캐시
   - 1-3. 높은 압축률
2. [Immutable Parts](#2-immutable-parts-불변-파트)
   - 2-1. 빠른 쓰기
   - 2-2. 백그라운드 머지
3. [Granule](#3-granule-그래뉼)
   - 3-1. Sparse Index vs Dense Index
   - 3-2. 설계 방식 (정렬 / 카디널리티 / 매크로 파티션)
4. [벤치마크](#4-벤치마크)
5. [결론](#5-결론)
6. [참고 자료](#6-참고-자료)

---

## 1. Columnar Storage (컬럼 지향 저장)

### 1-1. Row-oriented vs Column-oriented

같은 로그 데이터를 두 방식으로 저장하면 다음과 같습니다.

```
원본 데이터
| time     | service | status | url         | latency |
| 10:00:01 | api     | 200    | /users/1    | 12      |
| 10:00:01 | web     | 404    | /favicon    | 3       |
| 10:00:02 | api     | 500    | /orders     | 340     |

행 지향 (MySQL, PostgreSQL)
[10:00:01|api|200|/users/1|12][10:00:01|web|404|/favicon|3][10:00:02|api|500|/orders|340]

컬럼 지향 (ClickHouse) — 컬럼마다 별도 파일
time.bin    : [10:00:01, 10:00:01, 10:00:02]
service.bin : [api, web, api]
status.bin  : [200, 404, 500]
url.bin     : [/users/1, /favicon, /orders]
latency.bin : [12, 3, 340]
```

| | 행 지향 | 컬럼 지향 |
|---|---|---|
| 강점 | 한 행 전체 조회·수정 (OLTP) | 많은 행의 일부 컬럼 집계 (OLAP) |
| `SELECT status, count() GROUP BY status` | 모든 컬럼을 디스크에서 읽음 | **`status.bin`만 읽음** |
| `SELECT * WHERE id = 123` | 한 위치에서 바로 읽음 | 컬럼 파일 N개에서 모아야 함 |
| 1행 UPDATE | 제자리 수정 | 비쌈 (파트 재작성) |

로그 집계 쿼리는 보통 컬럼 수십 개 중 **2~5개만** 읽습니다. 컬럼이 50개인 테이블에서
3개만 읽으면, 압축 효과를 빼고도 I/O가 대략 1/15로 줄어듭니다.

### 1-2. SIMD와 CPU 캐시

**SIMD (Single Instruction, Multiple Data)** — 넓은 레지스터에 값 여러 개를 담아 명령
한 번으로 같은 연산을 수행합니다.

| 명령어 세트 | 레지스터 폭 | Int32 동시 처리 |
|---|---|---|
| SSE2 / SSE4.2 (x86) | 128bit | 4개 |
| AVX2 (x86) | 256bit | 8개 |
| AVX-512 (x86) | 512bit | 16개 |
| NEON (ARM, Graviton 등) | 128bit | 4개 |

SIMD는 **같은 타입의 값이 메모리에 빈틈없이 연속**해 있어야 한 번에 레지스터로 읽을 수
있습니다. 행 지향에서는 `status` 값이 다른 컬럼 사이에 흩어져 있어 불가능하지만, 컬럼
지향에서는 메모리 안에서도 C++ 연속 배열(`PaddedPODArray`)이라 바로 적용됩니다. 배열 끝에
패딩을 둬서 남은 몇 개 원소 때문에 경계 검사를 하지 않고도 끝까지 넓은 단위로 읽습니다.

```
status 컬럼 (UInt16 연속 배열)
[200, 404, 200, 500, 200, 200, 503, 200, 200, 301, 200, 200, 404, 200, 200, 502]
                 │  비교 명령 1번으로 여러 값을 동시에 처리
                 ▼
status >= 500 → [0,0,0,1,0,0,1,0,0,0,0,0,0,0,0,1]   ← 분기 없는 0/1 마스크
```

ClickHouse에서 SIMD가 쓰이는 대표적인 곳:

- **필터(WHERE)**: 조건 결과를 `if` 분기가 아닌 0/1 마스크로 만들고, 그 마스크로 다른
  컬럼을 한꺼번에 걸러냅니다. 분기 예측 실패(1회당 15~20 사이클)가 없습니다.
- **집계**: `sum`/`min`/`max`/`count`는 연속 배열 루프라 여러 레지스터에 부분합을 동시에
  쌓습니다.
- **문자열 검색**: `LIKE '%error%'`, `position` 등은 패턴의 첫 바이트를 16~64바이트씩
  한꺼번에 비교해 후보 위치만 찾습니다. 문자열 컬럼은 "이어 붙인 바이트 배열 + 오프셋
  배열"로 저장돼 블록 전체를 큰 버퍼 하나로 훑습니다.
- **그 밖에**: LZ4 압축 해제, 해시 계산, 정렬 일부, `LowCardinality` 인덱스 처리.
- **런타임 디스패치**: 같은 함수를 SSE4.2/AVX2/AVX-512용으로 여러 벌 컴파일해 두고,
  실행 시 CPU를 감지해 가장 넓은 버전을 고릅니다.

**CPU 캐시** — 현대 CPU는 계산보다 데이터를 기다리는 데 시간을 더 쓰기 쉽습니다.

```
레지스터          ~0.3ns
L1 캐시  ~32-48KB  ~1ns
L2 캐시  ~1-2MB    ~3-5ns
L3 캐시  수십 MB    ~10-20ns   (코어 공유)
DRAM     수십 GB    ~80-100ns   ← L1보다 약 100배 느림
```

- **캐시 라인 활용률**: CPU는 메모리를 64바이트 캐시 라인 단위로 가져옵니다. 행 지향에서
  `status`(2바이트)만 필요하면 64바이트를 가져와 2바이트만 쓰지만(약 3%), 컬럼 지향에서는
  64바이트가 전부 `status` 값입니다(100%).
- **순차 접근과 프리페처**: 배열을 앞에서부터 읽으면 하드웨어 프리페처가 다음 캐시 라인을
  미리 가져와 DRAM 대기가 숨겨집니다.
- **블록 단위 실행**: 연산자는 행 하나가 아니라 약 6.5만 행짜리 컬럼 블록을 주고받습니다.
  블록이 필터 → 계산 → 부분 집계를 거치는 동안 캐시에 머물고, 행 단위 실행(Volcano
  모델)의 행당 가상 함수 호출 비용을 사실상 없앱니다.
- **GROUP BY 해시 테이블**: 해시 테이블은 무작위 접근이라 캐시 미스가 가장 큰 병목입니다.
  ClickHouse는 `UInt8`/`UInt16` 키를 고정 크기 배열로 직접 인덱싱하고, 키 타입별로 특화된
  해시 테이블을 쓰며, 키가 많아지면 256개 하위 테이블로 나누는 2단계(two-level) 해시
  테이블과 소프트웨어 프리페치(`enable_software_prefetch_in_aggregation`)로 대응합니다.
- **JIT 컴파일(`compile_expressions`)**: `a * 2 + b > 100` 같은 식을 LLVM으로 하나의
  루프로 합쳐, 중간 결과 컬럼을 메모리에 썼다 읽는 트래픽을 없앱니다.

**한계**: 카디널리티가 높은 GROUP BY(예: `GROUP BY UserID, URL`)는 해시 테이블이 L3를
넘으면 캐시 미스가 지배적이 되며 SIMD로 해결되지 않습니다. 가변 길이 문자열, 복잡한
정규식, JSON 파싱은 SIMD를 일부에만 적용할 수 있습니다.

### 1-3. 높은 압축률

한 컬럼 안에는 같은 타입의 비슷한 값이 모여 있고 정렬 키 순서로 놓여 있어 압축이 매우 잘
됩니다.

```
service 컬럼 (정렬 후): api, api, api, ..., web, web, web, ...   → 긴 반복
time 컬럼:             1700000001, 1700000001, 1700000002, ...   → 차이값 0, 1, 0, 1...
```

컬럼 성격에 맞춰 코덱을 지정할 수 있습니다.

```sql
CREATE TABLE logs (
    time     DateTime CODEC(DoubleDelta, ZSTD),  -- 단조 증가 타임스탬프: 차이의 차이 ≈ 0
    service  LowCardinality(String),             -- 종류가 적은 문자열 → 딕셔너리 + 정수 인덱스
    status   UInt16 CODEC(T64, LZ4),             -- 작은 정수: 필요한 비트만 사용
    latency  Float32 CODEC(Gorilla, LZ4),        -- 시계열 실수값
    message  String CODEC(ZSTD(3))               -- 로그 본문: 범용 고압축
) ...
```

- 로그 데이터는 보통 **10배 이상** 압축됩니다.
- 압축은 저장 비용뿐 아니라 **속도**에도 기여합니다. 디스크와 메모리에서 읽는 바이트가
  줄고, LZ4 해제는 코어당 수 GB/s로 빨라서 "작게 읽고 CPU에서 푸는" 편이 대개 더 빠릅니다.
- 행 지향은 한 행 안에 시간·문자열·숫자가 섞여 있어 이 수준의 압축률이 나오지 않습니다.

---

## 2. Immutable Parts (불변 파트)

### 2-1. 빠른 쓰기

INSERT 한 번(배치 하나)은 디스크의 **새 파트 디렉터리 하나**가 됩니다.

```
INSERT (10만 행)
   │ 1. 메모리에서 ORDER BY 키로 정렬
   │ 2. 컬럼별로 압축
   │ 3. 새 디렉터리로 기록 → 끝
   ▼
/var/lib/clickhouse/data/db/logs/
   202610_1_1_0/   ← 파트: time.bin, service.bin, ..., primary.idx, ...
```

- 기존 데이터를 건드리지 않습니다. 행을 찾아 수정하는 일도, B-Tree 페이지 분할도, 행 단위
  락도 없습니다.
- 파트는 한 번 쓰이면 바뀌지 않으므로(immutable), 읽는 쿼리는 락 없이 일관된 스냅샷을
  봅니다.
- 그 결과 한 노드가 초당 수십만~수백만 행을 받아낼 수 있습니다.

**주의점** — 파트가 INSERT 단위로 생기므로 **작은 INSERT를 자주 하면 파트가 폭증**하고,
결국 `Too many parts` 오류로 쓰기가 막힙니다. 배치를 크게 만들어야 합니다.

- 클라이언트에서 수천~수만 행씩 묶기
- `async_insert=1` (서버가 대신 묶어 줌)
- Kafka 엔진 / Kafka Connect

관련 실험: [GUIDE.md](./GUIDE.md)의 인제스트 백프레셔 실험,
[KAFKA-INTEGRATION.md](./KAFKA-INTEGRATION.md).

### 2-2. 백그라운드 머지

작은 파트들은 백그라운드 스레드가 계속 **큰 파트로 합칩니다**. MergeTree라는 이름이
여기서 나왔습니다.

```
202610_1_1_0  ┐
202610_2_2_0  ├─ merge ─▶ 202610_1_3_1  ┐
202610_3_3_0  ┘                         ├─ merge ─▶ 202610_1_5_2
202610_4_4_0  ─────────────────────────┤
202610_5_5_0  ─────────────────────────┘
          (이름 규칙: 파티션_최소블록_최대블록_머지레벨)
```

- 각 파트가 이미 정렬돼 있어 머지는 merge sort 한 번이면 되고, 순차 읽기·쓰기라 비용이
  쌉니다.
- 쓰기 응답과 분리돼 있어 INSERT는 머지를 기다리지 않습니다.
- 머지된 원래 파트는 잠시 뒤 삭제되며, 진행 중인 쿼리는 원래 파트를 계속 읽으므로
  안전합니다.

머지할 때 엔진에 따라 데이터 변환도 일어납니다.

| 엔진 | 머지 시 동작 | 로그 용도 |
|---|---|---|
| `MergeTree` | 합치기만 함 | 원본 로그 |
| `ReplacingMergeTree` | 같은 키는 최신 버전만 남김 | 중복 제거 (결과적 일관성) |
| `SummingMergeTree` | 같은 키의 숫자를 합산 | 카운터 |
| `AggregatingMergeTree` | 집계 상태(`-State`)를 병합 | Materialized View 사전 집계 |

머지는 **언제 끝날지 보장되지 않습니다.** `ReplacingMergeTree`의 중복이 즉시 사라지지
않을 수 있으므로, 정확한 결과가 필요하면 쿼리에 `FINAL`을 쓰거나 `argMax` 등으로
처리해야 합니다.

---

## 3. Granule (그래뉼)

그래뉼은 ClickHouse가 데이터를 읽는 **최소 단위**이며 기본값은 **8,192행**
(`index_granularity`)입니다. 파트 안의 각 컬럼은 그래뉼 단위로 나뉘고, 쿼리는 어느
그래뉼을 읽을지 정한 뒤 그래뉼째로 읽습니다.

### 3-1. Sparse Index vs Dense Index

```
Dense Index (B-Tree, MySQL/PostgreSQL)
  모든 행마다 인덱스 항목 1개
  1억 행 → 인덱스 항목 1억 개 → 디스크에 저장, 일부만 메모리에 캐시

Sparse Index (ClickHouse primary.idx)
  그래뉼마다(8,192행마다) 첫 행의 키 1개만
  1억 행 → 인덱스 항목 약 12,200개 → 수백 KB, 항상 메모리에 상주
```

```
primary.idx (ORDER BY service, time)
 mark 0:   (api, 10:00:00)  → 행 0 ~ 8191
 mark 1:   (api, 10:05:12)  → 행 8192 ~ 16383
 mark 2:   (api, 10:11:40)  → ...
 ...
 mark 900: (web, 10:00:03)

WHERE service = 'api' AND time BETWEEN '10:05' AND '10:10'
 → 이진 탐색으로 mark 1~2만 후보 → 그래뉼 2개(약 1.6만 행)만 읽음
```

| | Dense (B-Tree) | Sparse (ClickHouse) |
|---|---|---|
| 인덱스 크기 | 데이터에 비례해 큼 | 매우 작음 (데이터의 약 1/8192) |
| 정확한 1행 찾기 | 매우 빠름 | 그래뉼 하나(8,192행)를 통째로 읽어야 함 |
| 범위 스캔 | 행마다 랜덤 I/O 가능 | 연속된 그래뉼을 순차로 읽음 |
| 쓰기 비용 | 행마다 인덱스 갱신 | 파트 생성 시 한 번에 작성 |
| 적합한 용도 | OLTP, point lookup | OLAP, 범위 스캔·집계 |

Sparse index는 "정확히 그 행"을 찾는 장치가 아니라 **"해당 없는 그래뉼을 빠르게
건너뛰는"** 장치입니다. 수십억 행 중 몇 %만 읽는 로그 쿼리에 맞습니다.

**Data Skipping Index**도 같은 원리로, 정렬 키가 아닌 컬럼도 그래뉼 묶음 단위의 요약
정보로 건너뛸 수 있게 합니다.

```sql
INDEX idx_status status   TYPE minmax                  GRANULARITY 4,  -- 범위 요약
INDEX idx_trace  trace_id TYPE bloom_filter            GRANULARITY 4,  -- 특정 값 존재 여부
INDEX idx_msg    message  TYPE tokenbf_v1(10240, 3, 0) GRANULARITY 4   -- 로그 본문 토큰 검색
```

### 3-2. 설계 방식

Sparse index가 얼마나 많이 건너뛸지는 **데이터를 어떻게 배치했느냐**에 달려 있습니다.

#### 3-2-1. 정렬 (`ORDER BY`)

`ORDER BY`는 곧 기본 키이자 **디스크상의 물리적 순서**입니다. 자주 필터하는 컬럼을 앞에
둬야 그래뉼 건너뛰기가 작동합니다.

```sql
-- 좋은 예: 대부분의 쿼리가 "특정 서비스의 최근 N시간"
ORDER BY (service, level, time)

-- 나쁜 예: time이 맨 앞
ORDER BY (time, service)
-- → WHERE service='api'만 쓰면 api 행이 모든 그래뉼에 흩어져 있어 건너뛰지 못함
```

- 기본 키는 **왼쪽부터** 효과가 큽니다. 두 번째 이후 컬럼만으로 필터하면 효과가 크게
  줄어듭니다.
- 정렬은 압축률에도 영향을 줍니다(1-3). 비슷한 값이 연속될수록 압축이 잘 됩니다.
- 기본 키는 유일하지 않아도 됩니다. 중복을 막는 제약이 아니라 배치 순서입니다.
- 접근 패턴이 둘 이상이면 **Projection**으로 다른 정렬 순서의 복사본을 같은 테이블 안에
  둘 수 있습니다(관련 실험: [GUIDE.md](./GUIDE.md)의 Projection 실험).

#### 3-2-2. 카디널리티 (Cardinality)

정렬 키는 보통 **카디널리티(값 종류 수)가 낮은 컬럼에서 높은 컬럼 순**으로 둡니다.

```
ORDER BY (service, level, time)
          ~20개    ~5개   거의 유니크

정렬 결과:
 api/ERROR/10:00 ... api/ERROR/23:59 | api/INFO/... | ... | web/ERROR/... | web/INFO/...
 └─ 같은 (service, level) 조합이 긴 연속 구간을 이룸
```

- **낮은 카디널리티를 앞에** 두면 각 값이 긴 연속 구간을 차지해, 필터 시 그래뉼을 크게
  덩어리째 건너뛰고, 뒤 컬럼(`time`)도 각 구간 안에서 정렬돼 2차 필터가 잘 작동하며,
  같은 값이 길게 반복돼 압축률도 좋아집니다.
- **높은 카디널리티를 앞에** 두면(예: `ORDER BY (request_id, service)`) 뒤 컬럼들이 사실상
  무작위 순서가 되어 건너뛰기도 압축도 거의 되지 않습니다.
- 다만 **쿼리 패턴이 우선**입니다. 카디널리티가 낮아도 쿼리에서 필터하지 않는 컬럼이면
  앞에 둘 이유가 없습니다.
- 낮은 카디널리티 문자열에는 `LowCardinality(String)`을 쓰면 저장과 연산이 모두
  빨라집니다.

#### 3-2-3. 매크로 파티션 (`PARTITION BY`)

그래뉼이 **작은 단위(micro)**의 건너뛰기라면, 파티션은 **큰 단위(macro)**로 데이터를
나눕니다.

```
PARTITION BY toYYYYMMDD(time)

logs/
 ├─ 20261011_*  (파티션: 10월 11일 파트들)
 ├─ 20261012_*
 └─ 20261013_*
       └─ 각 파트 안: 그래뉼 + sparse index
```

| 역할 | 설명 |
|---|---|
| 파티션 프루닝 | `WHERE time >= today()`이면 다른 날짜 파티션은 열어 보지도 않음 |
| 수명 관리 | `TTL time + INTERVAL 30 DAY` → 파티션 통째로 삭제, 행 단위 DELETE 비용 없음 |
| 운영 단위 | `DROP/DETACH/MOVE PARTITION`, 파티션 단위 백업·복구 |
| 스토리지 계층 | 오래된 파티션을 S3/HDD로 이동 (`TTL ... TO VOLUME 'cold'`) |
| 머지 경계 | 머지는 파티션 안에서만 일어남 |

**흔한 실수는 파티션을 너무 잘게 나누는 것**입니다.

```sql
PARTITION BY (toDate(time), service)   -- ✗ 날짜 × 서비스 = 파티션 폭증
PARTITION BY toStartOfHour(time)       -- ✗ 하루 24개, 1년이면 8,760개
```

- INSERT 하나가 여러 파티션에 걸치면 파티션마다 파트가 하나씩 생겨 `Too many parts`로
  이어집니다.
- 파티션은 **필터 도구가 아닙니다.** 필터는 `ORDER BY`(그래뉼)가 맡고, 파티션은 데이터
  수명과 운영 단위로 정합니다. 로그라면 보통 **일 단위 또는 월 단위**가 적당합니다.

#### 설계 예시: 로그 테이블

```sql
CREATE TABLE logs (
    time     DateTime CODEC(DoubleDelta, ZSTD),
    service  LowCardinality(String),
    level    LowCardinality(String),
    status   UInt16,
    trace_id String,
    message  String CODEC(ZSTD(3)),
    INDEX idx_trace trace_id TYPE bloom_filter            GRANULARITY 4,
    INDEX idx_msg   message  TYPE tokenbf_v1(10240, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)           -- macro: 일 단위 수명 관리
ORDER BY (service, level, time)         -- micro: 낮은→높은 카디널리티, 자주 쓰는 필터 순
TTL time + INTERVAL 30 DAY;             -- 파티션 단위로 싸게 삭제
```

쿼리 하나가 읽는 범위는 다음 순서로 좁혀집니다.

```
WHERE time >= now() - INTERVAL 1 HOUR AND service = 'api' AND level = 'ERROR'

전체 파트 ─[파티션 프루닝]──▶ 오늘 파티션만
          ─[primary index]──▶ api/ERROR 구간의 최근 1시간 그래뉼만
          ─[skipping index]─▶ (추가 조건이 있으면 더 제거)
          ─[PREWHERE]───────▶ 필터 컬럼부터 읽고, 통과한 그래뉼에서만 나머지 컬럼
          ─[SIMD·벡터화]────▶ 남은 데이터를 블록 단위로 병렬 집계
```

---

## 4. 벤치마크

### 4-1. ClickBench (공개 벤치마크)

ClickHouse 팀이 운영하는 OLAP 벤치마크입니다(결과: https://benchmark.clickhouse.com/).
아래 내용은 2026-10-13 기준 ClickBench README를 확인해 정리했습니다.

| 항목 | 내용 |
|---|---|
| 데이터 | 실제 웹 분석 서비스 데이터를 난독화한 `hits` 단일 평면 테이블, **99,997,497행**, 컬럼이 많은 비정규화 구조. Parquet은 의도적으로 "dirty"(논리 타입·bloom filter 없음) |
| 쿼리 | 풀 스캔, 필터 스캔, 인덱스 조회, 주요 관계 연산을 다루는 **43개** SQL |
| 실행 | 쿼리당 3회. 1회차 = cold run, 2·3회차 = hot run(둘 중 짧은 값 사용) |
| Cold run | **True cold**: 첫 실행 전 OS 페이지 캐시와 DB 캐시를 비우고 DB를 재시작. **Lukewarm cold**: 페이지 캐시만 비움(`no-cold` 태그 필수) |
| 점수 | 쿼리별 최고 기록 대비 `(10ms + 시간) / (10ms + 최고 시간)` 비율의 **기하평균** |
| 실패 쿼리 | `max(해당 시스템의 최대 실행 시간, 300초) × 2`로 벌점 처리 |
| Combined 지표 | 가중 기하평균: hot 60%, cold 20%, 적재 시간 10%, 저장 크기 10% |
| 기본 하드웨어 | AWS c6a.4xlarge (16 vCPU, 32GB RAM, 500GB gp2). 이후 c6a.2xlarge, c6a.metal, c8g.4xlarge, c7a.metal-48xl 등 추가 |
| 인덱스 | 기본 키 하나만(클러스터드 또는 논클러스터드). 수동 보조 인덱스는 **권장하지 않음** |
| 사전 집계 | 사전 집계 테이블, Projection, Materialized View는 **권장하지 않음** — 넣으면 참고용으로 표시되고 경쟁에서 제외 |
| 캐시 | 쿼리 결과 캐시 금지. 원본 데이터 캐시(buffer pool)는 허용 |

**이 리포트 관점에서 읽는 법**

- 사전 집계를 쓰지 않으므로, ClickBench는 1~3장의 **순수 스캔·집계 성능**(컬럼 저장, SIMD,
  압축, sparse index)을 재는 벤치마크입니다.
- 반대로 **인제스트 처리량과 머지 부하**, **분산 확장성**, **조인이 많은 스키마**는 거의
  측정하지 않습니다. README도 단일 평면 테이블, 약 1억 행이라는 작은 규모, 대부분 단일
  노드 결과라는 한계를 밝히고 있습니다.
- 동시성은 README의 한계 항목에 "쿼리를 하나씩 순차 실행한다"고 적혀 있지만, 공통
  드라이버(`lib/benchmark-common.sh`)에 메인 측정 이후 **보조 동시 QPS 테스트**가
  추가됐습니다. 메인 점수는 여전히 순차 실행 기준입니다.
- ClickHouse 팀이 직접 운영하는 벤치마크이며, README 스스로 "All Benchmarks Are Liars"라고
  밝히고 있으므로 맥락을 감안해 해석해야 합니다.

### 4-2. 이 레포에서 직접 측정한 결과

둘 다 서버형 ClickHouse가 아니라 **임베디드 ClickHouse인 chDB**로 측정했습니다.

**속도 비교** ([CHDB-SPEED-BENCHMARK.md](./CHDB-SPEED-BENCHMARK.md) — 2,000만 행, 엔진당
2GB 메모리 캡, median 초)

| 연산 | pandas | chDB | Polars | DuckDB |
|---|---|---|---|---|
| groupby, 낮은 카디널리티 (100그룹) | 0.263 | 0.091 | 0.024 | **0.022** |
| groupby, 높은 카디널리티 (200만 그룹) | 1.279 | **0.483** | 0.451 | 2.058 |
| filter + sum | 0.068 | 0.038 | 0.015 | **0.006** |
| top-10 정렬 | OOM | 0.243 | OOM | **0.003** |

- 모든 연산에서 1등인 엔진은 없습니다. 컬럼 엔진은 대체로 pandas보다 빠르지만 엔진 간
  순위는 연산 유형에 따라 바뀝니다.
- 엔진 간 차이가 가장 크게 벌어진 것은 **해시 테이블이 캐시를 넘는 높은 카디널리티
  groupby**였습니다(1-2의 한계와 일치).

**메모리 한계 비교** ([CHDB-BENCHMARK.md](./CHDB-BENCHMARK.md) — 3,200컬럼 × 25만 행,
원본 약 6.4GB, 3,200개 컬럼 전체 `avg()`)

| 메모리 한도 | pandas | chDB |
|---|---|---|
| 8GB | 86초 후 OOM Kill | (미측정) |
| 1.5GB | 즉시 OOM Kill | **성공** (12.25초, peak RSS 1,508MB) |
| 800MB | (미측정) | 실패, 단 정상적인 예외로 종료 |

- 컬럼을 블록 단위로 읽어 집계하는 구조 덕분에 chDB는 **메모리보다 큰 데이터**를
  처리했고, 전체를 메모리에 올려야 하는 pandas는 같은 한도에서 실패했습니다.

**동시 실행 시 지연** ([GUIDE.md](./GUIDE.md) 28절 — 6코어 공유 VM, 파드 1개에서 로컬
CPU 쿼리)

- 배치 쿼리 3개와 경합하면 단독 1.10초짜리 실시간 쿼리가 p50 약 2.4초로 **2배 넘게**
  느려졌습니다.
- CPU Workload Scheduling으로 루트 슬롯 상한(2)과 우선순위를 함께 걸었을 때 p50 1.12초로
  단독 실행 수준을 회복했고, 그 대가로 배치 처리량이 약 33% 감소했습니다.
- 순차 실행 벤치마크 수치만으로는 이런 운영 환경의 동작을 예측할 수 없다는 사례입니다.

### 4-3. 벤치마크를 볼 때 주의할 점

- 벤치마크는 **특정 워크로드 하나**를 잴 뿐입니다. 같은 엔진도 카디널리티, 쿼리 유형,
  하드웨어(AVX-512 유무, 캐시 크기, 메모리 대역폭)에 따라 순위가 바뀝니다. ClickBench가
  인스턴스별로 결과를 따로 보여 주는 이유입니다.
- 가장 믿을 만한 벤치마크는 **실제 데이터, 쿼리 패턴, 동시성으로 직접 측정한 결과**입니다.

---

## 5. 결론

| 특징 | 핵심 | 효과 |
|---|---|---|
| 컬럼 저장 | 필요한 컬럼만, 연속 배열로 | I/O 감소, SIMD·캐시 효율, 높은 압축률 |
| 불변 파트 | 쓰기는 새 파트 생성, 정리는 백그라운드 머지 | 빠른 대량 쓰기, 락 없는 읽기 |
| 그래뉼 + sparse index | 8,192행 단위 + 작은 인덱스 | 수십억 행에서 필요한 범위만 읽음 |
| 설계 (정렬·카디널리티·파티션) | 데이터 배치가 성능을 결정 | 같은 엔진이라도 설계에 따라 큰 차이 |

이 설계의 대가로 다음 영역은 약합니다.

- 행 단위 UPDATE/DELETE (내부적으로 파트를 다시 쓰는 mutation)
- 잦은 소량 INSERT (파트 폭증)
- 단일 행 조회(point lookup)와 트랜잭션
- 즉시 중복 제거 보장 (Kafka 재전송 등으로 생긴 중복은 별도 처리 필요)

로그처럼 **추가만 하고 대량으로 집계하는** 데이터에서는 이 약점이 거의 드러나지 않기
때문에, ClickHouse는 실시간 로그 집계에 특히 잘 맞습니다.

---

## 6. 참고 자료

- ClickBench: https://github.com/ClickHouse/ClickBench (결과: https://benchmark.clickhouse.com/)
- ClickHouse 문서 — MergeTree 엔진: https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree
- ClickHouse 문서 — 기본 키와 sparse index: https://clickhouse.com/docs/guides/best-practices/sparse-primary-indexes
- 이 레포의 관련 문서
  - [GUIDE.md](./GUIDE.md) — 클러스터 구축과 운영 실험 (백프레셔, Projection, 스필오버, 워크로드 격리 등)
  - [KAFKA-INTEGRATION.md](./KAFKA-INTEGRATION.md) — Kafka 엔진 연동과 엣지 케이스
  - [CHDB-BENCHMARK.md](./CHDB-BENCHMARK.md), [CHDB-SPEED-BENCHMARK.md](./CHDB-SPEED-BENCHMARK.md) — chDB 벤치마크
