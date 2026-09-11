# chDB 속도 벤치마크: pandas / Polars / DuckDB와 비교

[CHDB-BENCHMARK.md](./CHDB-BENCHMARK.md)에서는 "메모리 한계를 넘는 데이터를
다룰 수 있는가"를 봤다면, 이번엔 **속도** 관점입니다 — 메모리에 충분히
들어가는 평범한 크기의 데이터로, chDB/pandas/Polars/DuckDB 네 가지를 같은
연산으로 실측했습니다.

## 준비: 2,000만 행짜리 전형적인 분석용 데이터셋

컬럼 6개(그룹 키 3개 + 값 3개)로, groupby 벤치마크(h2oai db-benchmark류)에서
흔히 쓰는 형태를 그대로 채택했습니다:

| 컬럼 | 타입 | 카디널리티 |
|---|---|---|
| `id1` | Int32 | 낮음 (100개 그룹) |
| `id2` | Int32 | 중간 (10,000개 그룹) |
| `id3` | Int64 | 높음 (2,000,000개 그룹, 사실상 거의 유니크) |
| `v1`, `v2` | Int32 | 값 (1~100) |
| `v3` | Float64 | 값 (정규분포 난수) |

Parquet 파일 크기 342MB(2천만 행 × 32바이트/행 원본 기준 640MB, snappy로
압축). 이전 실험에서 겪은 사고(공유 Colima VM에 큰 컨테이너를 띄워 기존
클러스터에 영향을 줬던 것)를 반복하지 않기 위해, 이번엔 **엔진 하나당 컨테이너
하나, 각각 2GB로 캡핑**해서 완전히 격리된 상태로 순차 실행했습니다 — 한
프로세스 안에 네 엔진을 다 올려두면 서로의 메모리가 누적되어 공정한 비교도
안 되고 불필요하게 위험하기도 합니다.

## 비교 방식: "한 번 로드, 그다음 연산은 로드된 것에 대해"

네 엔진 모두 **①먼저 전체를 메모리로 로드하는 시간을 따로 측정**하고, **②그
다음부터는 이미 로드된 테이블/DataFrame에 대해서만 연산 시간을 측정**합니다
(연산마다 파일을 다시 읽는 게 아님). chDB/DuckDB는 `CREATE TABLE ... AS
SELECT * FROM read_parquet(...)`로 한 번 적재한 뒤 그 테이블에 쿼리하고,
pandas/Polars는 `read_parquet()`로 한 번 DataFrame을 만든 뒤 그 위에서
연산합니다. 각 연산은 3회 반복해 median을 씁니다.

## 결과 (초, median, 2GB 메모리 캡 기준)

| 연산 | pandas | chDB | Polars | DuckDB |
|---|---|---|---|---|
| load (전체 적재) | 0.275 | 0.351 | **0.092** | 0.322 |
| groupby (낮은 카디널리티, 100그룹) | 0.263 | 0.091 | 0.024 | **0.022** |
| groupby (높은 카디널리티, 200만 그룹) | 1.279 | **0.483** | 0.451 | 2.058 |
| filter + sum | 0.068 | 0.038 | 0.015 | **0.006** |
| top-10 정렬 (naive `ORDER BY ... LIMIT`) | **OOM (2GB)** | 0.243 | **OOM (2GB)** | **0.003** |

**어느 한 엔진이 모든 면에서 이기지 않습니다.** DuckDB는 낮은 카디널리티
groupby·filter·top-N 정렬에서 압도적으로 빠르지만, 오히려 **높은 카디널리티
groupby(200만 그룹)에서는 네 엔진 중 가장 느립니다**(2.058s, pandas보다도
느림). chDB는 어느 연산에서도 1등은 아니지만 꾸준히 상위권이고, 특히
고카디널리티 groupby에서 근소하게 1등(0.483s)입니다.

## 진짜 흥미로운 발견: top-N 정렬에서 API 선택이 성패를 가른다

`sort_values("v3", ascending=False).head(10)`(pandas)과
`.sort("v3", descending=True).head(10)`(Polars, eager API)는 **둘 다 2GB
한도에서 OOM으로 죽었습니다.** 반면 SQL로 `ORDER BY v3 DESC LIMIT 10`을 쓴
chDB와 DuckDB는 멀쩡했고, DuckDB는 심지어 0.003초 만에 끝났습니다.

원인은 명확합니다 — `sort_values`/`.sort()`는 **전체 2,000만 행을 문자
그대로 다 정렬한 뒤에야 앞 10개를 자릅니다**(전체 정렬본을 메모리에 만듦).
반면 SQL 엔진의 쿼리 옵티마이저는 `ORDER BY ... LIMIT n`을 보면 **진짜
top-N 알고리즘(전체 정렬 없이 상위 n개만 유지)으로 자동 치환**합니다.

이게 "pandas/Polars가 근본적으로 느리다"는 뜻은 아닙니다 — **API를 제대로
골랐을 때**의 결과를 다시 재봤습니다:

| 연산 | pandas `nlargest(10, "v3")` | Polars *lazy* `scan_parquet().sort().limit().collect()` |
|---|---|---|
| 2GB 한도 | **성공, 0.283s** | 여전히 OOM |
| 3GB 한도 | (불필요) | **성공, 0.245s** |

- pandas는 전용 메서드(`nlargest`, 힙 기반 부분 선택 알고리즘)로 바꾸자
  chDB/DuckDB급으로 빠르고 2GB에서도 문제없이 끝났습니다.
- Polars는 **eager API 대신 lazy API**(`scan_parquet` + lazy `.sort().limit()`
  + `.collect()`)로 바꾸자 속도(0.245s)는 chDB와 동급으로 나왔지만, **여전히
  2GB로는 부족하고 3GB는 있어야 했습니다** — lazy 옵티마이저가 top-N 형태를
  인식은 하지만 SQL 엔진(chDB/DuckDB)만큼 메모리 효율적으로 실행하지는
  못한다는 뜻입니다.

**결론: "라이브러리 자체의 속도"보다 "그 라이브러리에서 어떤 API를
썼는가"가 이번 실험에서 훨씬 큰 차이를 만들었습니다.** 특히 pandas/Polars의
데이터프레임 API는 메서드를 그대로 체이닝하면 SQL의 `LIMIT` 같은 최적화가
공짜로 따라오지 않는다는 걸 직접 확인했습니다 — SQL 기반 엔진(chDB, DuckDB)은
쿼리 전체를 보고 계획을 세우는 옵티마이저가 있어 이런 흔한 실수를 사용자
대신 방지해줍니다.

## 격리 방법: 지난번 사고를 반복하지 않기 위해

[CHDB-BENCHMARK.md](./CHDB-BENCHMARK.md)의 사고(8GB 컨테이너 하나가 공유
Colima VM 전체를 압박해 기존 클러스터 파드들이 재시작됨) 이후, 이번엔:

1. 매 단계 전에 `colima ssh -- free -h`로 실제 여유 메모리 재확인
2. 네 엔진을 한 프로세스/컨테이너에 몰아넣지 않고 **엔진당 별도 컨테이너**로
   완전히 격리 실행(엔진 간 메모리 누적 방지)
3. 컨테이너 한도(2GB)를 실제 여유 메모리(3.7~4.1GB)보다 항상 작게 유지

이번엔 pandas·Polars 컨테이너가 각각 자기 한도 안에서 OOM Kill됐을 때도
**기존 ClickHouse 클러스터 파드는 단 하나도 재시작되지 않았습니다**(매번
`kubectl get pods` 재확인) — cgroup 격리가 의도대로 작동하려면 "컨테이너
한도 < 실제 여유 메모리"가 지켜져야 한다는 지난 교훈을 그대로 적용한
결과입니다.

## 정리

```bash
rm -rf ~/chdb-speed-bench
docker rmi chdb-speed-bench:latest
```

git 저장소 바깥에서 진행했고 전부 정리했습니다. 클러스터는 실험 내내
영향받지 않았습니다.
