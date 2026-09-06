# 프로덕션 체크리스트 점검 보고서

**점검일**: 2026-09-07
**점검 대상**: `kind-clickhouse-lab` (4샤드×3레플리카 CHI + 3노드 CHK + Prometheus/Grafana)
**기준 문서**: [PRODUCTION.md](./PRODUCTION.md)

이 문서는 [PRODUCTION.md](./PRODUCTION.md)의 체크리스트를 **현재 랩 클러스터의 실제
설정에 대고 그대로 점검한 스냅샷**입니다. 이 랩은 프로덕션이 아니라 실험 목적이므로
다수 항목이 기준에 못 미치는 게 자연스럽습니다 — 왜 그런지, 실제 프로덕션이라면
무엇을 바꿔야 하는지를 함께 남겼습니다. **이 점검을 근거로 클러스터를 수정하지는
않았습니다** — 점검 시점의 상태를 있는 그대로 기록한 문서입니다.

---

## 점검 결과 표

| # | 항목 | 상태 | 실측 결과 |
|---|---|---|---|
| 1 | Keeper 안티어피니티 | ❌ | `keeper-0-0`, `keeper-0-2`가 **같은 노드**(`clickhouse-lab-worker`)에 공존. 재구축 때마다 배치가 달라지는 것으로 보아 **명시적 안티어피니티 규칙이 아예 없고**(`chk.yaml`에 `affinity` 필드 자체가 없음) 스케줄러 재량에 맡겨져 있음 |
| 2 | PVC 사용 | ✅ (부분) | 12개 PVC 전부 정상 바인딩 — 데이터 유실은 안 됨. 다만 StorageClass가 `rancher.io/local-path`라 **특정 노드에 종속**된 스토리지(그 노드가 죽으면 PV도 같이 사라짐) — 프로덕션이라면 클라우드 SSD/NVMe 기반 PV로 교체 필요 |
| 3 | 이미지 태그 고정 | ❌ | `clickhouse/clickhouse-server:head` — PRODUCTION.md 8절에서 스스로 "금지"라고 문서화한 이동(moving) 태그를 여전히 사용 중 |
| 4 | 리소스 requests/limits | ❌ | `{}` — **전혀 설정되어 있지 않음**. 12개 CH 파드가 물리 코어를 무제한으로 경합 중이며, 이는 GUIDE.md 15절에서 관찰한 `max_parallel_replicas` 역효과의 근본 원인이기도 함 |
| 5 | PodDisruptionBudget | ✅ | Altinity 오퍼레이터가 `chi-chi-cluster1`, `chk-chk-keeper` 두 개를 **자동 생성**(`maxUnavailable=1`) — 별도 조치 불필요, 뜻밖의 합격 |
| 6 | `max_memory_usage` 기본 프로파일 상한 | ❌ | `0`(무제한), 컴파일드 기본값 그대로(`changed=0`) — 안전 상한이 설정되어 있지 않음 |
| 7 | `max_server_memory_usage_to_ram_ratio` | ⚠️ | `0.9`(기본값 그대로) — PRODUCTION.md 5절에서 권장한 공유 호스트용 `0.8`보다 높음 |
| 8 | `async_insert` / `wait_for_async_insert` | ℹ️ | **둘 다 이미 `1`** — 그런데 `changed=0`(순정 기본값)으로 나타남. 이는 우리가 껐다 켠 게 아니라, 이 빌드(`26.9.1-testing`, `:head` 태그로 받은 nightly)의 **컴파일드 기본값 자체가 이미 async_insert=on**이라는 뜻으로 보임 — PRODUCTION.md 4절에서 인용한 "async_insert는 기본 꺼짐"이라는 공식 문서 서술과 배치되는 흥미로운 발견 (버전/빌드에 따른 기본값 차이일 가능성, 추가 확인 필요) |
| 9 | `parts_to_delay_insert` / `parts_to_throw_insert` | ✅ | 1000 / 3000, 문서 기본값과 일치, 커스터마이즈되지 않음(현재 랩 규모에선 무관) |
| 10 | 기본 사용자 비밀번호 | ❌ | `default` 사용자가 **빈 비밀번호**로 인증 성공(`clickhouse-client --password=`로 확인) — PRODUCTION.md 10절에서 경고한 상태 그대로 |
| 11 | 백업 | ❌ | `system.backups` 0건 — `BACKUP`/`RESTORE` 실행 이력이 전혀 없음. 실험 데이터라 백업 대상은 아니었지만, 실제 프로덕션이었다면 치명적 공백 |
| 12 | Prometheus 알람 규칙 | ❌ | 스크레이프 설정에 `rule_files`/`alerting` 섹션 자체가 없음 — GUIDE.md 12절 대시보드로 사람이 "볼" 수는 있지만, 이상 징후를 자동으로 "알림받을" 수 있는 체계는 없음 |

---

## 분류별 정리

### 잘 지켜진 것
- PVC 기반 영구 스토리지 (데이터 유실 방지 자체는 확보됨)
- PodDisruptionBudget — 오퍼레이터가 별도 설정 없이도 자동 생성
- MergeTree part 임계값(`parts_to_delay_insert`/`parts_to_throw_insert`) — 문서 기본값과 일치

### 바로 고쳐야 할 것 (프로덕션 전제라면)
- 리소스 requests/limits 미설정
- 이미지 태그가 `:head` 이동 태그로 고정되어 있지 않음
- 기본 사용자(`default`)가 빈 비밀번호
- Keeper 파드에 명시적 안티어피니티 규칙 없음 (배치가 스케줄러 운에 좌우됨)

### 운영 프로세스 공백
- `BACKUP`/`RESTORE`를 단 한 번도 실행한 적 없음
- Prometheus 알람 규칙 없음 (관측은 가능하나 자동 알림 체계 없음)
- `max_memory_usage` 안전 상한 미설정 (쿼리 하나가 서버 메모리를 무제한 사용 가능)

### 추가 확인이 필요한 발견
- `async_insert`/`wait_for_async_insert`가 이미 `1`로 켜져 있는데 `changed=0`으로 보고됨 —
  이 랩에서 쓰는 `:head` 빌드(`26.9.1-testing`)의 컴파일드 기본값 자체가 최근 바뀐 것인지,
  아니면 다른 경로(빌드 플래그 등)로 주입된 것인지는 별도로 확인이 필요함.

---

## 참고

- 점검에 사용한 원본 쿼리/명령은 이 문서에 별도로 남기지 않았습니다 — 필요하면
  [PRODUCTION.md](./PRODUCTION.md)의 각 절에 대응하는 `system.*` 조회, `kubectl get
  pdb`/`describe pod`/`get storageclass` 등을 그대로 재실행해 재현할 수 있습니다.
- 이 보고서는 특정 시점의 스냅샷입니다. 클러스터를 재구축(`kind delete` →
  재적용)하면 Keeper/파드 배치 등 일부 항목(특히 1번, 3번)의 결과가 달라질 수
  있습니다.
