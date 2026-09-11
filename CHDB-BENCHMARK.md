# chDB vs pandas: 메모리 한계를 넘는 와이드 데이터 벤치마크

pandas 대체재를 리서치(chDB/Polars/DuckDB 최신 동향)해본 뒤, 그중 이 랩과 가장
맞닿아 있는 **chDB**(서버 없이 파이썬 프로세스 안에 임베디드로 동작하는
ClickHouse)를 실제로 pandas와 맞대결시켜봤습니다. 목표는 리서치에서 나온
"vendor 자체 발표 수치라 신뢰도가 낮다"는 한계를 메우는 것 — 특히 **컬럼 수가
아주 많고(3,000개 이상), 프로세스에 허용된 메모리보다 큰 데이터**를 다룰 때
chDB가 정말 pandas와 질적으로 다르게 동작하는지를 직접 확인하는 것이었습니다.

## 준비: 3,200컬럼 × 25만 행 Parquet (원본 크기 약 6.4GB)

macOS 호스트에서 직접 실행했습니다(이 랩의 kind 클러스터와는 무관 — chDB는
단일 프로세스 임베디드 라이브러리라 별도 Docker 컨테이너로 격리).

```dockerfile
FROM python:3.11-slim
RUN pip install --no-cache-dir chdb pandas pyarrow numpy
WORKDIR /data
```

```bash
docker build -t chdb-bench:latest .
```

설치된 버전(2026-09 시점): **chdb 4.3.0**(chdb-core 26.7.3), **pandas 3.0.5**,
pyarrow 25.0.1 — 리서치에서 확인했던 "chDB 4.x 세대", "pandas 3.0 정식 출시"와
정확히 일치했습니다. (2026-09-11 PyPI 기준 재확인: `chdb`/`chdb-core` 모두
4.3.0/26.7.3이 여전히 최신 버전 — 별도 venv에 새로 설치해 직접 검증.)

`float64` 컬럼 3,200개(`col_0000` ~ `col_3199`), 25만 행을 pyarrow
`ParquetWriter`로 5,000행씩 배치 기록(생성 자체가 메모리를 과하게 먹지 않도록):

```python
N_COLS, N_ROWS, BATCH_ROWS = 3200, 250_000, 5_000
schema = pa.schema([(f"col_{i:04d}", pa.float64()) for i in range(N_COLS)])
writer = pq.ParquetWriter("/data/wide_data.parquet", schema, compression="snappy")
for _ in range(N_ROWS // BATCH_ROWS):
    arrays = [pa.array(rng.standard_normal(BATCH_ROWS)) for _ in range(N_COLS)]
    writer.write_table(pa.Table.from_arrays(arrays, schema=schema))
```

결과: **디스크 7.2GB**(무작위 실수라 snappy 압축 효율이 낮아 원본 raw
크기(6.4GB)보다 오히려 큼), 완전히 펼쳤을 때 파이썬 객체로는 **최소 6.4GB**.

## 비교 쿼리: 두 엔진에 "같은 일"을 시킨다

공정한 비교를 위해 컬럼 몇 개만 건드리는 쉬운 쿼리가 아니라, **3,200개 컬럼
전부**에 대해 평균을 구하는 쿼리를 씁니다 — pandas의 `df.mean()`과 동등한,
전체 컬럼을 다 훑어야 하는 작업입니다.

```python
query = "SELECT count(*) AS cnt, " + ", ".join(f"avg(col_{i:04d})" for i in range(3200)) \
        + " FROM file('/data/wide_data.parquet', Parquet)"
```

pandas 쪽은 애초에 `pd.read_parquet()`로 전체를 DataFrame으로 펼쳐야
`.mean()`을 계산할 수 있으므로, **읽기 자체가 이미 "전체 컬럼 다 훑기"와
동급**입니다.

## 결과: 같은 메모리 한도에서 하나는 죽고, 하나는 산다

Docker `--memory`/`--memory-swap`로 컨테이너 메모리를 하드 캡핑해 비교:

| 메모리 한도 | pandas (`read_parquet` + 준비) | chDB (`avg()` × 3200 + `count()`) |
|---|---|---|
| 8 GB | **실패** — 86초 후 OOM Kill (exit 137) | (테스트 안 함, 아래 참고) |
| 1.5 GB | **실패** — 즉시 OOM Kill (exit 137, 출력 없이 강제 종료) | **성공** — 12.25초, peak RSS 1,508MB |
| 800 MB | (테스트 안 함) | **실패** — 단, 깔끔한 예외로 |

```
# pandas @ 1.5GB, 8GB 둘 다: 아무 출력도 없이 그냥 프로세스가 죽음
$ echo $?
137
```

```
# chDB @ 1.5GB: 성공
Low memory system detected (1.50 GiB). Setting dirty_decay_ms=0
SUCCESS: elapsed=12.25s, ...
peak_rss_mb=1508.0
```

```
# chDB @ 800MB: 실패하지만 방식이 다름 — 파이썬 예외로 잡을 수 있음
Low memory system detected (800.00 MiB). Setting dirty_decay_ms=0
RuntimeError: Code: 241. DB::Exception: (total) memory limit exceeded:
  would use 724.07 MiB (attempt to allocate chunk of 4.00 MiB),
  current RSS: 706.89 MiB, maximum: 720.00 MiB
  (MEMORY_LIMIT_EXCEEDED)
```

**핵심 발견 1 — pandas는 8GB로도 부족했다.** 6.4GB 원본 데이터를 읽는 데
8GB 한도로도 OOM이 났다는 건, Parquet→Arrow→pandas 변환 과정(컬럼마다 별도
numpy 배열 생성, block manager 조립)에서 원본 크기의 몇 배에 달하는 임시
메모리가 필요하다는 뜻입니다. **3,200개라는 컬럼 수 자체가 pandas에게
불리한 조건**이라는 것도 한몫합니다 — 컬럼마다 파이썬/numpy 객체 오버헤드가
붙기 때문입니다.

**핵심 발견 2 — 실패하는 방식 자체가 다르다.** pandas는 OS 커널의 OOM killer가
프로세스를 SIGKILL로 통째로 죽입니다(exit 137) — 파이썬 코드 안에서는
`try/except`로 잡을 방법이 없고, 로그 한 줄 안 남기고 사라집니다. 반면 chDB는
ClickHouse 엔진 내부의 메모리 트래커가 스스로 한도(컨테이너의 cgroup 한도를
자동 감지 — 로그의 "Low memory system detected")를 인지하고, 한도에
근접하면 **커널이 개입하기 전에 스스로 멈춰서 일반 파이썬 예외를
던집니다**(`Code: 241, MEMORY_LIMIT_EXCEEDED`, 정확히 몇 MiB가 부족한지까지
알려줌). 프로덕션에서 이 차이는 큽니다 — chDB는 재시도/폴백 로직을 정상적인
예외 처리로 짤 수 있지만, pandas가 이런 식으로 죽으면 외부 프로세스
감시(supervisor, k8s liveness probe 등)가 없으면 원인 파악조차 어렵습니다.

**공정성 참고**: 이 쿼리(전체 컬럼 평균)는 여전히 컬럼 지향 스캔이라 chDB의
강점이 드러나는 조건이긴 합니다 — ClickHouse는 컬럼을 블록 단위로 스트리밍
처리하며 한 번에 전체를 파이썬 객체로 펼치지 않는 반면, pandas의
`DataFrame`은 애초에 "전체를 한 번에 메모리에 올리는" 것을 전제로 설계된
자료구조라는 게 이 격차의 근본 원인입니다. 즉 이건 "쿼리를 유리하게
골랐다"기보다 **두 도구의 근본적인 실행 모델 차이**를 보여주는 결과에
가깝습니다.

## 겪은 사고: cgroup 메모리 제한은 "그 컨테이너"만 보장하지, "호스트 전체 여유"는 보장하지 않는다

8GB 한도 pandas 테스트를 돌리기 전, 기존 클러스터가 이미 이 랩의 공유
Colima VM(총 16GB)에서 15Gi 중 13Gi를 쓰고 있어 여유가 2Gi 남짓이라는 걸
확인했었습니다. 그런데 **두 번째 라운드(1.5GB → 800MB → 8GB 순으로 테스트를
확장하며)에서 여유 메모리를 다시 확인하지 않고 8GB 한도 컨테이너를 그대로
띄웠고**, 그 결과:

```
$ kubectl get pods -n clickhouse
chi-chi-cluster1-0-0-0   1/1   Running   3 (47s ago)   40m   ← 재시작
chi-chi-cluster1-1-0-0   1/1   Running   1 (80s ago)   41h   ← 재시작
...(대부분의 CH 파드가 1~3회 재시작)
chi-chi-cluster1-3-1-0   0/1   Running   2 (15s ago)          ← 일시적으로 다운
```

**Docker의 `--memory` 한도는 "그 컨테이너가 그 이상은 못 쓰게" 막아줄 뿐,
"시스템 전체에 그만큼의 물리 메모리가 남아있음"을 보장하지 않습니다.**
공유 VM이 이미 빠듯한 상태에서 8GB짜리 컨테이너가 실제로 그 한도를 채우려
들자, 호스트(정확히는 이 VM) 전체의 물리 메모리가 바닥나면서 **커널의 전역
OOM killer가 애꿎은 기존 ClickHouse 파드들을 골라 죽였습니다** — 벤치마크
컨테이너 자신이 아니라요. 다행히 StatefulSet + Keeper 쿼럼 덕분에 15~30초
안에 전부 자동 복구됐고(`system.replicas`에 `is_readonly`/
`is_session_expired` 걸린 레플리카 없음, 기존 `kafka_demo.events` 데이터도
멀쩡함), 데이터 유실은 없었습니다.

**교훈**: 공유 리소스 환경에서 메모리 캡을 건 컨테이너를 돌릴 때는, 캡 값을
올릴 때마다 **그 시점의 실제 여유 메모리를 다시 확인**해야 합니다. cgroup
격리는 "이 컨테이너가 이웃에게 폐 끼치지 않게"가 아니라 "이 컨테이너 자신을
어디까지 허용할지"만 정하는 것이라, 호스트가 이미 빠듯하면 격리된 컨테이너
하나 때문에 무관한 다른 워크로드가 죽을 수 있습니다.

## 리서치 결과와의 접점

이전 리서치에서 지적했던 "chDB의 성능 수치(247배 빠름 등)는 전부 ClickHouse
자체 발표라 신뢰도가 낮다"는 한계는 여전히 유효하지만, 이번 실측은 그것과는
**질적으로 다른 주장**을 독립적으로 검증한 것입니다: chDB의 강점은 단순히
"더 빠르다"가 아니라, **pandas가 아예 로드조차 못 하는 크기의 데이터를
같은 메모리 예산 안에서 처리할 수 있다**는 것, 그리고 **메모리 부족 상황을
프로세스 강제 종료가 아니라 정상적인 예외로 처리한다**는 것입니다. 이 두
가지는 벤더 발표 수치와 무관하게 이번 실험에서 직접 재현/확인됐습니다.

## 정리

```bash
rm -rf ~/chdb-bench-data
docker rmi chdb-bench:latest
```

이 실험은 git 저장소 바깥(`~/chdb-bench-data`)에서 진행했고 전부 정리했습니다.
클러스터 쪽도 사고 이후 전체 파드 `Running`, 레플리카 정상, 기존 데이터
무손상을 확인했습니다.
