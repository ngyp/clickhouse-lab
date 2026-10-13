# ClickHouse 클러스터 실험 가이드 (kind + Altinity Operator + Keeper)

로컬 macOS(Colima + kind)에서 3샤드 × 3레플리카 ClickHouse 클러스터를 ClickHouse Keeper 기반으로
구성하고, 장애 복구 동작을 실습하는 가이드입니다.

## 0. 사전 준비물

| 도구 | 확인 명령 | 비고 |
|---|---|---|
| Docker CLI | `docker --version` | Colima를 백엔드로 사용 |
| Colima | `colima version` | Docker 런타임 (Docker Desktop 대체) |
| kind | `kind --version` | Kubernetes-in-Docker |
| kubectl | `kubectl version --client` | |
| helm | `helm version` | Altinity Operator 설치용 |

작업 디렉터리: `~/zzz/clickhouse/manifests/`에 모든 YAML을 보관합니다.

---

## 1. Docker 런타임(Colima) 기동 및 리소스 확보

```bash
colima start                     # 이미 떠 있다면 생략
docker info --format 'CPUs: {{.NCPU}}, Memory: {{.MemTotal}}'
```

3샤드×3레플리카(9 파드) + Keeper 3노드 + 오퍼레이터를 안정적으로 띄우려면
**최소 6 vCPU / 16GB**를 권장합니다. 기존 리소스가 부족하면:

```bash
colima stop
colima start --cpu 6 --memory 16 --disk 60
```

> 다른 워크로드(다른 kind 클러스터, docker-compose 스택 등)가 같은 Colima VM을
> 공유하고 있다면 재시작 시 함께 재기동됩니다. 리소스가 부족하면 API 서버가
> `TLS handshake timeout`처럼 불안정해지니, 먼저 `docker stats --no-stream`으로
> 여유 자원을 확인하세요.

### 1-1. (multi-node kind에서만 필요) inotify 한도 상향
wk 
kind로 워커 노드를 여러 개 띄우면 Colima VM의 기본 `fs.inotify.max_user_instances`(128)가
부족해 `kube-proxy`가 `too many open files`로 CrashLoop에 빠지고 워커 노드가
`NotReady`에 머무를 수 있습니다. 미리 올려둡니다.

```bash
colima ssh -- sudo sh -c "
  sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576
  echo 'fs.inotify.max_user_instances=1024' > /etc/sysctl.d/99-kind.conf
  echo 'fs.inotify.max_user_watches=1048576' >> /etc/sysctl.d/99-kind.conf
  sysctl -p /etc/sysctl.d/99-kind.conf
"
```

---

## 2. kind 클러스터 생성

`manifests/kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: clickhouse-lab
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
```

```bash
kind create cluster --config manifests/kind-config.yaml
kubectl --context kind-clickhouse-lab get nodes    # 4개 노드 모두 Ready 확인
```

정리할 때는 `kind delete cluster --name clickhouse-lab`.

---

## 3. Altinity ClickHouse Operator 설치 (Helm)

```bash
helm repo add altinity https://helm.altinity.com
helm repo update altinity
helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --kube-context kind-clickhouse-lab \
  --namespace clickhouse --create-namespace
```

```bash
kubectl --context kind-clickhouse-lab -n clickhouse get pods    # operator 2/2 Running 확인
kubectl --context kind-clickhouse-lab get crd | grep altinity   # CHI/CHK CRD 확인
```

---

## 4. ClickHouse Keeper 배포 (CHK, 3노드)

`manifests/chk.yaml`:

```yaml
apiVersion: "clickhouse-keeper.altinity.com/v1"
kind: "ClickHouseKeeperInstallation"
metadata:
  name: chk
  namespace: clickhouse
spec:
  configuration:
    clusters:
      - name: "keeper"
        layout:
          replicasCount: 3
```

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/chk.yaml

# 완료까지 폴링
kubectl --context kind-clickhouse-lab -n clickhouse get chk chk -w
```

`Completed` 상태가 되면 `keeper-chk`라는 클라이언트 서비스(2181/TCP)가 생성됩니다.
**서비스 이름 규칙: `keeper-<CHK 리소스 이름>`.**

---

## 5. ClickHouse 클러스터 배포 (CHI, 3샤드×3레플리카 + PVC)

`manifests/chi.yaml`:

```yaml
apiVersion: "clickhouse.altinity.com/v1"
kind: "ClickHouseInstallation"
metadata:
  name: chi
  namespace: clickhouse
spec:
  defaults:
    templates:
      dataVolumeClaimTemplate: default-volume-claim
  configuration:
    zookeeper:
      nodes:
        - host: keeper-chk       # 4단계에서 만든 Keeper 서비스
          port: 2181
    clusters:
      - name: "cluster1"
        layout:
          shardsCount: 3
          replicasCount: 3
  templates:
    volumeClaimTemplates:
      - name: default-volume-claim
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi
```

> **PVC는 필수입니다.** `dataVolumeClaimTemplate` 없이 배포하면 각 파드가
> `emptyDir`(임시 디스크)를 쓰게 되어, 파드가 재시작될 때마다 로컬 데이터와
> 테이블 스키마가 통째로 사라집니다 (7-2절 참고).

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get chi chi -w   # Completed 대기 (9 hosts)
kubectl --context kind-clickhouse-lab -n clickhouse get pods -o wide
kubectl --context kind-clickhouse-lab -n clickhouse get pvc
```

---

## 6. 클러스터 토폴로지 및 샤딩/복제 검증

### 6-1. 토폴로지 확인

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- \
  clickhouse-client -q "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num FORMAT PrettyCompact"
```

### 6-2. ReplicatedMergeTree + Distributed 테이블 생성

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE events_local ON CLUSTER 'cluster1'
(
    id UInt64,
    event_time DateTime,
    payload String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events_local', '{replica}')
ORDER BY id
"

kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE events ON CLUSTER 'cluster1' AS events_local
ENGINE = Distributed('cluster1', currentDatabase(), events_local, rand())
"
```

### 6-3. 데이터 삽입 및 분산/복제 확인

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
INSERT INTO events SELECT number, now(), concat('payload-', toString(number)) FROM numbers(9000)
"

# Distributed 테이블 총합 (9000이어야 함)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"

# 샤드별 분산 (대략 균등 분배)
for pod in chi-chi-cluster1-0-0-0 chi-chi-cluster1-1-0-0 chi-chi-cluster1-2-0-0; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SELECT count() FROM events_local"
done

# 샤드0의 3개 레플리카가 서로 동일한지 (복제 확인)
for pod in chi-chi-cluster1-0-0-0 chi-chi-cluster1-0-1-0 chi-chi-cluster1-0-2-0; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SELECT count() FROM events_local"
done
```

---

## 7. 장애 복구 실험

### 7-1. 파드만 삭제 (PVC 유지) → 완전 자동 복구

```bash
kubectl --context kind-clickhouse-lab -n clickhouse delete pod chi-chi-cluster1-0-1-0

# 재기동 대기
kubectl --context kind-clickhouse-lab -n clickhouse get pod chi-chi-cluster1-0-1-0 -w

# 데이터가 즉시 그대로 살아있는지 확인 (같은 PVC 재부착)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-1-0 -- clickhouse-client -q "SELECT count() FROM events_local"
kubectl --context kind-clickhouse-lab -n clickhouse get pvc default-volume-claim-chi-chi-cluster1-0-1-0   # 볼륨 이름/나이 그대로인지 확인
```

**결과**: StatefulSet이 파드를 재생성하고, 같은 PVC를 그대로 재부착하므로
재동기화 없이 즉시 정상. 이것이 K8s + PVC 조합의 기본 자가치유입니다.

### 7-2. 파드 + PVC 삭제 (진짜 디스크 유실) → 수동 개입 필요

StatefulSet 컨트롤러가 파드를 즉시 재생성하며 같은 이름의 PVC를 다시 물고 들어가려 하기
때문에, `kubectl delete pod` + `kubectl delete pvc`를 동시에 실행하면 경합(race)이 생겨
PVC 삭제가 `Terminating` 상태로 멈출 수 있습니다. 해당 오디널의 StatefulSet을 잠깐
0으로 스케일해서 경합 없이 처리합니다.

```bash
# 1) 특정 레플리카의 StatefulSet을 찾아 0으로 스케일 (파드+finalizer 해제)
kubectl --context kind-clickhouse-lab -n clickhouse get statefulset | grep "0-1"
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chi-chi-cluster1-0-1 --replicas=0
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/chi-chi-cluster1-0-1-0 --timeout=60s

# 2) PVC 삭제 (이제 아무도 참조하지 않으므로 즉시 삭제되고 local-path 디렉터리도 정리됨)
kubectl --context kind-clickhouse-lab -n clickhouse delete pvc default-volume-claim-chi-chi-cluster1-0-1-0

# 3) 다시 1로 스케일 → 완전히 새로운 빈 PVC로 파드 재생성
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chi-chi-cluster1-0-1 --replicas=1
kubectl --context kind-clickhouse-lab -n clickhouse get pod chi-chi-cluster1-0-1-0 -w
```

**증상 확인**:

```bash
# 테이블이 사라짐 (SHOW TABLES 결과 없음)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-1-0 -- clickhouse-client -q "SHOW TABLES"

# 다른 노드에서 보면 이 레플리카가 비활성으로 인지됨 (active_replicas < total_replicas)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SELECT replica_name, active_replicas, total_replicas FROM system.replicas WHERE table='events_local'"

# 그래도 Distributed 쿼리는 나머지 2개 레플리카로 자동 우회되어 계속 정상 응답
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q "SELECT count() FROM events"
```

**수동 복구 절차** (ReplicatedMergeTree의 진짜 자가치유는 여기서부터 자동):

```bash
# 1) Keeper에 남은 옛 레플리카 등록(좀비 상태) 정리
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SYSTEM DROP REPLICA 'chi-chi-cluster1-0-1' FROM ZKPATH '/clickhouse/tables/0/events_local'"

# 2) 빈 디스크에 테이블을 다시 붙임 (ON CLUSTER 아님, 이 노드에서만 실행)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-1-0 -- clickhouse-client -q "
CREATE TABLE events_local
(
    id UInt64,
    event_time DateTime,
    payload String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events_local', '{replica}')
ORDER BY id
"

# 3) 이후부터는 완전 자동: 파트가 피어로부터 다운로드되어 채워짐
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-1-0 -- clickhouse-client -q "SELECT count() FROM events_local"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-1-0 -- clickhouse-client -q \
  "SELECT event_time, event_type, part_name, rows FROM system.part_log WHERE table='events_local' AND event_type='DownloadPart' ORDER BY event_time"
```

### 7-3. 두 시나리오 요약

| 시나리오 | K8s 자동복구 | ClickHouse 자동복구 |
|---|---|---|
| 파드만 삭제 (PVC 유지) | O (재스케줄) | O (디스크 그대로라 즉시 정상) |
| 파드+PVC 삭제 (진짜 디스크 장애) | O (재스케줄, 빈 볼륨) | X — 스키마/레플리카 재등록은 수동 |
| (재등록 이후) | - | O — 파트 재동기화는 완전 자동 |

쿼리 가용성(장애 노드 자동 우회)은 항상 자동이지만, 노드 자체의 재구성(스키마 재등록)은
운영 환경에서는 보통 초기화 스크립트/오퍼레이터 부트스트랩으로 자동화합니다.

---

## 8. Distributed 테이블 로드밸런싱(`load_balancing`) 정책 실험

`load_balancing`은 Distributed 테이블이 **하나의 샤드 안에서 여러 레플리카 중 어느 것에
쿼리를 보낼지**를 결정하는 쿼리/세션 레벨 설정입니다 (`SETTINGS load_balancing='...'`).

### 8-1. 관찰용 트릭: `remote()` + `{a|b|c}` 문법

`remote()` 테이블 함수의 주소 표현식에서 **쉼표(`,`)는 서로 다른 샤드**(전체 조회 후 합침),
**중괄호+파이프(`{a|b|c}`)는 같은 샤드의 레플리카 후보**(그중 하나만 골라 조회)를 의미합니다.
샤드0의 세 레플리카를 "레플리카 그룹"으로 묶어 `hostName()`을 조회하면, 매 쿼리마다
실제로 어떤 레플리카가 선택됐는지 결과로 직접 확인할 수 있습니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one)
SETTINGS load_balancing='in_order'
"
```

### 8-2. 정책별 테스트

```bash
# in_order — 항상 목록의 첫 번째 레플리카만 선택
for i in $(seq 1 10); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='in_order'
  "
done

# random (기본값) — 균등 무작위 분산
for i in $(seq 1 15); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='random'
  "
done | sort | uniq -c

# nearest_hostname — 쿼리를 실행한 노드 자신과 이름이 같은 레플리카를 우선
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-2-0 -- clickhouse-client -q "
SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='nearest_hostname'
"

# first_or_random — 정상 상태에서는 in_order와 동일 (장애 시에만 무작위 폴백)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='first_or_random'
"
```

### 8-3. `round_robin`은 반드시 영구 Distributed 테이블로 테스트할 것

`remote()` 테이블 함수는 **호출마다 새 커넥션 풀을 생성**하기 때문에, 같은 세션 안에서
연달아 호출하거나 여러 개의 새 세션에서 반복 호출해도 회전(rotation) 상태가 유지되지
않고 매번 같은 레플리카가 선택됩니다. 진짜 회전을 보려면 **이미 만들어 둔 Distributed
테이블**(`events`, 클러스터 설정 로드 시 생성된 영구 커넥션 풀을 사용)로 테스트해야 합니다.

```bash
# 9000행이 있는 실제 테이블이므로 DISTINCT로 호스트만 추출 (LIMIT 없이 SELECT hostName()만 하면
# 행 수만큼 중복 출력되니 주의)
for i in $(seq 1 12); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
  SELECT DISTINCT hostName() FROM events SETTINGS load_balancing='round_robin'
  " | grep "^chi-chi-cluster1-0-"
done
```

기대 결과: 독립된 세션끼리도 `0-1 → 0-2 → 0-0 → 0-1 → ...` 처럼 주기 3으로 순환합니다.
(`remote()`로 테스트하면 항상 같은 호스트만 나오니 이 차이를 직접 비교해 보세요.)

### 8-4. 결과 요약

| 정책 | 관찰된 동작 |
|---|---|
| `in_order` | 항상 목록의 첫 번째 레플리카만 고정 선택 |
| `random` (기본값) | 균등 무작위 분산 |
| `nearest_hostname` | 쿼리를 실행한 노드 자기 자신과 이름이 같은 레플리카를 항상 우선 (로컬 우선 라우팅에 유용) |
| `round_robin` | **영구 Distributed 테이블의 클러스터 커넥션 풀**에서만 진짜로 회전. `remote()` 호출은 매번 새 풀을 만들어 회전하지 않음 |
| `first_or_random` | 정상 상태에서는 `in_order`와 동일, 장애 시에만 무작위 폴백 |

### 8-5. `first_or_random` 실제 장애 폴백 데모 (`in_order`와의 차이 실증)

`in_order`와 `first_or_random`은 **정상 상태에서는 동일하게 보이지만**, 첫 번째 레플리카가
죽었을 때 동작이 명확히 갈립니다. 샤드0의 첫 번째 레플리카(`chi-chi-cluster1-0-0`)만
내려서 비교합니다.

```bash
# 1) 첫 번째 레플리카만 다운
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chi-chi-cluster1-0-0 --replicas=0
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/chi-chi-cluster1-0-0-0 --timeout=60s

# 2) in_order — 죽지 않은 나머지 중 "다음 순서"인 0-1로 결정론적으로 고정
for i in $(seq 1 8); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='in_order'
  "
done

# 3) first_or_random — 살아있는 나머지(0-1, 0-2) 사이에서 무작위 분산
for i in $(seq 1 10); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{chi-chi-cluster1-0-0|chi-chi-cluster1-0-1|chi-chi-cluster1-0-2}', system.one) SETTINGS load_balancing='first_or_random'
  "
done | sort | uniq -c

# 4) 복구
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chi-chi-cluster1-0-0 --replicas=1
```

**실측 결과**: `in_order`는 8회 전부 `chi-chi-cluster1-0-1`로 고정. `first_or_random`은
10회 중 4회 `0-1`, 6회 `0-2`로 무작위 분산. 즉 `in_order`는 장애 시 "다음 순번"에
트래픽이 몰리고, `first_or_random`은 살아있는 레플리카들에 고르게 분산시켜 특정
레플리카로의 쏠림(thundering herd)을 막습니다.

---

## 9. 샤드 전체 장애 시나리오

레플리카 장애(같은 샤드 내 다른 레플리카로 자동 우회)와 달리, **샤드 전체**(그 샤드의
모든 레플리카)가 죽으면 그 샤드가 담당하는 데이터 자체를 조회할 방법이 없습니다.
이때 `skip_unavailable_shards` 설정이 동작을 좌우합니다.

```bash
# 1) 샤드2의 3개 레플리카 전부 다운
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset \
  chi-chi-cluster1-2-0 chi-chi-cluster1-2-1 chi-chi-cluster1-2-2 --replicas=0

# 2) 기본 설정 — 에러로 실패해야 함 (일부 데이터가 통째로 안 보이는 걸 방지하는 안전장치)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"
# => Code: 279 ALL_CONNECTION_TRIES_FAILED

# 3) skip_unavailable_shards=1 — 죽은 샤드를 건너뛰고 나머지로 부분 응답
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SELECT count() FROM events SETTINGS skip_unavailable_shards=1"
# => 5990  (9000 - 샤드2 몫 3010, 정확히 일치)

# 4) 복구
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset \
  chi-chi-cluster1-2-0 chi-chi-cluster1-2-1 chi-chi-cluster1-2-2 --replicas=1
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"
# => 9000 (복구 확인)
```

**핵심**: 레플리카는 "같은 데이터의 여분"이라 자동 폴백이 되지만, 샤드는 "서로 다른
데이터 조각"이라 다른 샤드가 대신 답해줄 수 없습니다. `skip_unavailable_shards`는
정확성보다 가용성이 중요한 대시보드/모니터링 쿼리 등에 명시적으로 켜서 쓰는
트레이드오프 설정입니다 (기본값 0 = 꺼짐, 즉 기본은 "정확성 우선").

---

## 10. Keeper 노드 장애 내성 테스트

Keeper 3노드는 Raft 합의를 사용하므로 과반(3개 중 2개)이 살아있어야 쓰기가 가능합니다.
1개 장애는 버티지만, 2개(과반 미만)가 죽으면 쿼럼을 잃습니다.

```bash
# 0) baseline: 3/3 정상 상태에서 insert
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q \
  "INSERT INTO events VALUES (99001, now(), 'keeper-test-baseline')"

# 1) Keeper 1개 다운 (2/3, 쿼럼 유지) — insert 정상 동작해야 함
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chk-chk-keeper-0-0 --replicas=0
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/chk-chk-keeper-0-0-0 --timeout=60s
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q \
  "INSERT INTO events VALUES (99002, now(), 'keeper-test-2of3')"   # 성공

# 2) Keeper 2번째까지 다운 (1/3, 쿼럼 상실)
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chk-chk-keeper-0-1 --replicas=0
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/chk-chk-keeper-0-1-0 --timeout=60s

# 3) ReplicatedMergeTree 로컬 테이블에 직접 insert 시도
#    (Distributed 테이블은 기본이 비동기 전송이라 실패를 숨김 — 반드시 events_local에 직접 넣어야
#     Keeper 쿼럼 의존성을 제대로 관찰할 수 있음)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q \
  "INSERT INTO events_local VALUES (99004, now(), 'direct-keeper-test')"
# => 응답 없이 멈춤 (에러로 즉시 실패하지 않고 쿼럼이 돌아올 때까지 대기)

# 4) (다른 터미널에서) Keeper 2개 복구 → 쿼럼 재형성
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset chk-chk-keeper-0-0 chk-chk-keeper-0-1 --replicas=1

# 5) 위 3)번에서 멈춰있던 insert가 자동으로 완료됨 (에러 없이, 대기만 하다가 성공)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-1-1-0 -- clickhouse-client -q "SELECT count() FROM events_local WHERE id=99004"
```

**핵심 발견**:
- Keeper 1노드 장애(2/3 유지)는 완전히 투명 — 쓰기/읽기 모두 정상.
- Keeper 과반 상실(1/3)이 되면 `ReplicatedMergeTree`로의 직접 INSERT가 **에러 없이 그냥
  멈춥니다** (즉시 실패하지 않고 쿼럼 복구를 기다림).
- `Distributed` 테이블에 대한 INSERT는 기본이 비동기(로컬 큐잉 후 백그라운드 전송)라
  겉보기엔 즉시 성공한 것처럼 보이지만, 실제로는 목적지 샤드에 반영되지 않고 대기열에
  쌓여 있을 뿐입니다 — 진짜 장애 내성을 테스트하려면 로컬 `*_local` 테이블에 직접
  써봐야 합니다.
- 쿼럼이 돌아오면 멈춰있던 INSERT와 대기열에 쌓였던 Distributed INSERT 모두 **자동으로
  완료**됩니다 — 데이터 유실 없이 지연만 발생.

---

## 11. 모니터링 (Prometheus + Grafana) 연동

이후 실험들의 관찰을 쉽게 하기 위해, ClickHouse 클러스터와 Altinity 오퍼레이터를
Prometheus + Grafana로 모니터링합니다. `kube-prometheus-stack` 같은 풀 스택은 우리
Colima VM(6 CPU/16GB, 이미 13개 파드 운영 중)에는 과합니다 — 대신 최소 구성의
Prometheus/Grafana를 순수 kubectl 매니페스트로 직접 배포합니다. 네임스페이스는 별도로
만들지 않고 기존 `clickhouse` 네임스페이스를 재사용합니다.

### 11-1. ClickHouse 내장 Prometheus 익스포터 활성화

ClickHouse 기본 이미지의 `config.xml`에는 `<prometheus>` 블록이 **주석 처리된 채로**
이미 들어있습니다 (포트 9363, `/metrics` 엔드포인트). CHI의 `configuration.files`로
같은 내용을 주석 없이 추가하면 오퍼레이터가 ConfigMap을 통해 모든 파드에 배포합니다.

`manifests/chi.yaml`에 추가된 부분:

```yaml
spec:
  configuration:
    files:
      config.d/prometheus.xml: |
        <clickhouse>
            <prometheus>
                <endpoint>/metrics</endpoint>
                <port>9363</port>
                <metrics>true</metrics>
                <events>true</events>
                <asynchronous_metrics>true</asynchronous_metrics>
                <status_info>true</status_info>
            </prometheus>
        </clickhouse>
```

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
```

> **주의**: `config.d`에 새 파일이 추가되는 변경은 ClickHouse가 즉시 핫리로드하지
> 못하고 프로세스 재시작이 필요했습니다 (기존 파일 수정은 보통 핫리로드되지만, 새
> 파일 추가는 재시작 전까지 포트가 열리지 않았습니다). PVC가 붙어있으므로 데이터
> 손실 없이 안전하게 재시작할 수 있습니다:
>
> ```bash
> for p in $(kubectl --context kind-clickhouse-lab -n clickhouse get pods -l clickhouse.altinity.com/chi=chi -o name); do
>   kubectl --context kind-clickhouse-lab -n clickhouse delete $p --wait=false
> done
> ```

확인:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- wget -qO- localhost:9363/metrics | head
```

### 11-2. Prometheus 배포 (파드 자동 디스커버리)

`manifests/monitoring/prometheus.yaml`에 ServiceAccount/ClusterRole(파드 조회 권한),
ConfigMap(스크레이프 설정), Deployment, Service를 정의합니다. 샤드/레플리카 수가
바뀌어도 대응할 수 있도록 고정 IP 목록이 아니라 `kubernetes_sd_configs`(role: pod)로
`clickhouse.altinity.com/chi=chi` 레이블을 가진 파드를 자동 탐색하고, 파드 IP의
9363 포트를 스크레이프 대상으로 relabel합니다. 오퍼레이터 자체 메트릭(고정
Service, 8888 포트)은 별도 job으로 정적 등록합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/monitoring/prometheus.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get pods -l app=prometheus
```

접속 및 확인:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/prometheus 9090:9090
# 다른 터미널에서
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health}'
curl -s 'http://localhost:9090/api/v1/query?query=ClickHouse_Info' | jq '.data.result | length'
```

실측: 오퍼레이터 타겟 1개 + ClickHouse 파드 9개(3샤드×3레플리카) = 총 10개 타겟이
모두 `up`, `ClickHouse_Info` 쿼리가 9개 시계열(파드당 1개, `shard`/`replica` 레이블
포함)을 반환합니다.

> **참고**: Altinity 오퍼레이터는 우리가 추가한 설정과 무관하게 **자체적으로도** 각
> ClickHouse 호스트의 메트릭을 폴링해서 `chi_clickhouse_event_*`,
> `chi_clickhouse_metric_*` 같은 이름으로 자기 메트릭 엔드포인트(8888)에 재노출하고
> 있었습니다. 즉 오퍼레이터만 스크레이프해도 기본적인 클러스터 메트릭은 얻을 수 있고,
> 우리가 각 파드를 직접 스크레이프하는 것은 오퍼레이터를 거치지 않는 더 세밀하고
> 지연 없는 원본 메트릭(`ClickHouseMetric_*`, `ClickHouseProfileEvents_*` 등)을 얻기
> 위함입니다.

### 11-3. Grafana 배포

`manifests/monitoring/grafana.yaml`은 Prometheus를 기본 데이터소스로 자동
프로비저닝합니다. 익명 접속을 Admin 권한으로 허용해 두어(랩 환경 전용, 외부 노출
없음 — ClusterIP + port-forward로만 접근) 바로 대시보드를 만들어볼 수 있고, 필요하면
`admin`/`admin`으로도 로그인할 수 있습니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/monitoring/grafana.yaml
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/grafana 3000:3000
# 브라우저에서 http://localhost:3000 접속 (또는 admin/admin 로그인)
```

데이터소스 헬스체크로도 확인 가능:

```bash
curl -s http://localhost:3000/api/datasources/uid/<uid>/health
# => {"status":"OK", "message":"Successfully queried the Prometheus API."}
```

### 11-4. 핵심 정리

- 풀 스택 대신 최소 구성(Deployment 2개 + ConfigMap 2개 + RBAC)으로 충분히 관찰 가능한
  환경을 만들 수 있음 — 리소스 여유가 빠듯한 로컬 kind 랩에 적합.
- ClickHouse의 Prometheus 익스포터는 이미지에 기본 내장(주석 처리)돼 있어 CHI
  `files`로 몇 줄만 추가하면 활성화됨. 단, **config.d에 새 파일을 추가하는 변경은
  파드 재시작이 필요**했다(기존 파일 수정과 다른 점).
- Kubernetes `kubernetes_sd_configs`(role: pod) + 레이블 기반 relabel을 쓰면 샤드/
  레플리카 수가 바뀌어도(뒤에 나올 리샤딩 실험 등) Prometheus 설정을 고칠 필요가
  없음.
- Altinity 오퍼레이터는 이미 자체적으로 클러스터 전체 메트릭을 집계해 노출하고
  있어서, 오퍼레이터 메트릭만으로도 상당 부분 관찰이 가능하다는 점은 예상 밖의
  수확이었음.

---

## 12. 가시성 (Observability)

11절에서 Prometheus/Grafana를 **배포**했다면, 이 절은 실제로 클러스터 상태를
**어떻게 들여다보는지** 다룹니다. 지금까지 실험 곳곳에서 즉흥적으로 썼던
`system.*` 쿼리들을 한곳에 정리하고, 실제로 동작하는 Grafana 대시보드를 붙이고,
"정상 vs 이상"을 판별하는 기준을 이 랩에서 실제로 관찰한 사례에 근거해 정리합니다.

### 12-1. `system.*` 쿼리 치트시트

아래 쿼리는 모두 재구축된 라이브 클러스터(4샤드×3레플리카)에서 직접 실행해
확인했습니다.

**클러스터 토폴로지**

```sql
-- 샤드/레플리카 구성 한눈에 보기
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num;
```

**복제 상태 (레플리카 헬스체크의 핵심)**

```sql
-- is_readonly=1이면 Keeper 연결 문제, active_replicas < total_replicas면 일부 레플리카 다운
SELECT database, table, replica_name, is_readonly, is_session_expired,
       active_replicas, total_replicas, log_pointer, log_max_index
FROM system.replicas;

-- 아직 처리되지 않은 복제 작업(fetch/merge/mutation) 큐 — 쌓이면 복제 지연 신호
SELECT count() FROM system.replication_queue;

-- 활성 파트에서 떨어져 나간(detached) 파트 — 정상 상태면 0
SELECT count() FROM system.detached_parts;
```

**Mutation / Merge 진행 상황**

```sql
-- 진행 중인 mutation (is_done=0이 오래 지속되면 이상 신호)
SELECT database, table, mutation_id, command, is_done, parts_to_do
FROM system.mutations WHERE NOT is_done;

-- 현재 실행 중인 병합
SELECT count() FROM system.merges;

-- 테이블별 활성 파트 수 (작은 파트가 과도하게 많으면 병합이 밀리고 있다는 신호)
SELECT table, count() AS parts, sum(rows) AS rows
FROM system.parts WHERE active GROUP BY table;
```

**쿼리 활동 / 저장공간**

```sql
-- 최근 5분간 처리한 쿼리 수
SELECT count() FROM system.query_log WHERE event_time > now() - INTERVAL 5 MINUTE;

-- 디스크 여유 공간 (PVC 용량 대비 사용량 확인)
SELECT name, path, free_space, total_space FROM system.disks;
```

**Keeper(ZooKeeper) 연결 상태**

```sql
-- 이 노드가 Keeper와 맺은 세션 상태 (session_uptime_elapsed_seconds, xid 등)
SELECT * FROM system.zookeeper_connection;
```

### 12-2. Grafana 대시보드 실제 구성

`manifests/monitoring/grafana.yaml`에 대시보드 프로비저닝을 추가했습니다.
Grafana의 파일 기반 프로비저닝은 두 계층으로 나뉩니다 — provider 설정(어느
폴더를 감시할지)과 실제 대시보드 JSON(그 폴더 안의 파일):

```yaml
# grafana-dashboard-provider ConfigMap → /etc/grafana/provisioning/dashboards
apiVersion: 1
providers:
  - name: default
    type: file
    options:
      path: /var/lib/grafana/dashboards

# grafana-dashboards ConfigMap → /var/lib/grafana/dashboards (실제 JSON)
```

패널을 만들기 전에 Prometheus가 실제로 어떤 메트릭을 노출하는지 먼저 확인했습니다
(추측하지 않고 `label/__name__/values`로 직접 조회):

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/label/__name__/values | jq -r '.data[]' | grep ^ClickHouseMetrics_ | head
```

ClickHouse 익스포터의 "현재값(gauge)" 계열 메트릭은 문서에 자주 나오는
`ClickHouseMetric_*`가 아니라 **`ClickHouseMetrics_*`**(끝에 s)였습니다 —
실제로 조회해보지 않았다면 놓쳤을 부분입니다. 이걸 바탕으로 9개 패널을
구성했고, 배포 전 모든 패널의 PromQL이 실제로 비어있지 않은 값을 반환하는지
하나씩 확인했습니다:

| 패널 | 쿼리 | 확인된 결과 |
|---|---|---|
| CH Pods Up | `sum(up{job="clickhouse-pods"})` | 12 |
| Operator Up | `up{job="clickhouse-operator"}` | 1 |
| Readonly Replicas | `sum(ClickHouseMetrics_ReadonlyReplica)` | 0 (정상) |
| ZooKeeper/Keeper Sessions | `sum(ClickHouseMetrics_ZooKeeperSession)` | 12 (파드 수와 일치) |
| Cluster Topology (표) | `ClickHouse_Info` | 12개 시계열, shard/replica/pod 라벨 포함 |
| Background Activity | `sum(ClickHouseMetrics_Merge)` / `PartMutation` / `ReplicatedFetch` | 3개 라인, 클러스터 전체 합산 |
| Query Rate per Pod | `rate(ClickHouseProfileEvents_Query[1m])` | 파드별 12개 라인 |
| Parts by State | `sum by (part_state) (ClickHouseDimensionalMetrics_merge_tree_parts)` | 5개 상태(Active/Outdated 등) |
| Operator Query Events by Host | `rate(chi_clickhouse_event_Query[5m])` | 오퍼레이터 경유, 호스트별 12개 라인 |

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/monitoring/grafana.yaml
kubectl --context kind-clickhouse-lab -n clickhouse rollout status deployment/grafana
```

프로비저닝 확인 (스크린샷 대신 API로):

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/grafana 3000:3000 &
curl -s -u admin:admin http://localhost:3000/api/search?query=ClickHouse
# => uid: clickhouse-lab-overview 대시보드가 검색됨
curl -s -u admin:admin http://localhost:3000/api/dashboards/uid/clickhouse-lab-overview
# => panels 배열에 9개 패널 모두 확인
```

브라우저에서는 `http://localhost:3000` 접속 후 "ClickHouse Lab Overview"
대시보드를 열면 됩니다(익명 Admin 접속 허용, 또는 admin/admin).

### 12-3. 장애/이상 징후 판별 기준

아래 표는 일반 문서가 아니라 **이 랩에서 지금까지의 실험을 통해 실제로 관찰한**
"정상 vs 이상" 신호입니다. 각 행은 해당 이상 징후를 실제로 만들어봤던 절을
가리킵니다.

| 신호 (쿼리/명령) | 정상일 때 | 이상 발생 시 실제 관찰 (해당 절) |
|---|---|---|
| `system.replicas.active_replicas` vs `total_replicas` | 두 값이 같음 | 레플리카가 디스크를 잃으면 `active_replicas < total_replicas`로 즉시 감소 (7-2절: PVC 삭제 실험) |
| `system.replicas.is_readonly` | 0 | Keeper 쿼럼을 잃으면 해당 레플리카가 읽기 전용으로 전환되고, `ReplicatedMergeTree` 쓰기가 멈춤 (10절: Keeper 쿼럼 상실 실험) |
| `system.mutations.is_done` + `parts_to_do` | 곧 1로 완료 | 배경 병합이 관리자에 의해 멈추면(`SYSTEM STOP MERGES`) mutation이 `is_done=0`으로 무기한 정체 (16절: Mutation & TTL 실험) |
| `system.replication_queue` 건수 | 0에 가까움, 금방 소진 | 대량 mutation/리샤딩 직후 일시적으로 급증했다가 서서히 감소 (13절: 리샤딩 실험) |
| `system.parts`의 테이블당 파트 수 | 적고 안정적 | 병합이 밀리면 작은 파트가 쌓임 — 단일 파트만 있는 작은 테이블은 `OPTIMIZE FINAL`조차 건너뛸 수 있다는 함정도 발견 (16절) |
| Keeper `mntr`의 `zk_server_state` | 전체 앙상블에서 리더 1개 + 팔로워 나머지 정확히 일치 | 네트워크 파티션 중에는 소수파가 팔로워 단절을 아직 감지 못해 스스로를 "리더"라고 오보고하는 과도기 상태가 존재 (17절: 네트워크 파티션 실험) |
| Grafana "Readonly Replicas" 패널 | 0 | 1 이상이면 즉시 조사 필요 — 위 `is_readonly` 신호를 대시보드로 상시 관찰하는 버전 |
| Grafana "ZooKeeper/Keeper Sessions" 패널 | 파드 수(현재 12)와 일치 | 세션 수가 줄면 일부 노드가 Keeper와 연결이 끊겼다는 뜻 |

### 12-4. 핵심 정리

- `system.*` 쿼리는 "지금 이 순간의 스냅샷"에 강하고, Grafana는 "시간에 따른
  추세"(병합이 밀리기 시작했다, 세션이 끊겼다 등)를 놓치지 않는 데 강함 — 둘을
  같이 써야 함.
- ClickHouse Prometheus 익스포터의 게이지 메트릭 prefix는 `ClickHouseMetrics_`
  (문서에서 흔히 보이는 `ClickHouseMetric_` 단수형이 아님) — 실제 조회 없이
  메트릭 이름을 추측하면 틀리기 쉬움.
- 이 랩의 "이상 징후" 기준표는 추상적인 알람 규칙이 아니라, 실제로 그 문제를
  일으켜보고 시스템 테이블에서 뭐가 바뀌는지 관찰한 결과입니다 — 장애주입
  실험(7, 10, 16, 17절)이 관측 가능성 설계에 직접적인 근거를 제공한 셈입니다.

---

## 13. 클러스터 확장 & 리샤딩 (3→4 샤드)

ClickHouse는 **샤드를 늘려도 기존 데이터를 자동으로 재분배하지 않습니다.** 샤딩은
`Distributed` 테이블의 샤딩 키(`rand()`)가 "현재 샤드 개수"를 기준으로 매 INSERT 시점에
어느 샤드로 보낼지 결정하는 것일 뿐, 이미 저장된 데이터는 그 결정이 다시 계산되지
않습니다. 이 실험은 그 사실을 직접 확인하고, 수동으로 재분배(리샤딩)하는 절차를 보여줍니다.

### 12-1. 샤드 확장

`manifests/chi.yaml`에서 `shardsCount`만 3→4로 변경합니다 (모니터링 절(11절)에서 추가한
`prometheus.xml` 설정은 그대로 둡니다):

```yaml
    clusters:
      - name: "cluster1"
        layout:
          shardsCount: 4      # 3 -> 4
          replicasCount: 3
```

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get chi chi -w   # Completed 대기 (12 hosts)
```

> **주의**: `shardsCount`를 바꾸면 오퍼레이터가 새 샤드(3개 파드)를 만드는 것과 별개로,
> 클러스터 토폴로지가 담긴 ConfigMap(`<remote_servers>`)이 바뀌므로 **기존 9개 파드도
> 전부 순차적으로 롤링 재시작**됩니다. 9개 재시작 + 3개 신규 생성이 순서대로 진행되니
> 실제로는 수 분 정도 걸립니다. (11절에서 설정한 Prometheus는 `kubernetes_sd_configs`
> 기반 자동 디스커버리라 별도 설정 변경 없이 타겟이 9개→12개로 자동 반영됩니다.)

### 12-2. 검증: 기존 데이터는 그대로, 새 데이터만 4개 샤드로 분산

```bash
# 토폴로지 확인 (4샤드 x 3레플리카 = 12 hosts)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num FORMAT PrettyCompact"

# 새 샤드(shard3)는 비어 있어야 함 — 기존 데이터는 옮겨오지 않음
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-3-0-0 -- clickhouse-client -q "SELECT count() FROM events_local"
# => 0

# 새 데이터를 추가로 삽입 (id >= 100000)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
INSERT INTO events SELECT number+100000, now(), concat('payload-', toString(number)) FROM numbers(4000)
"

# 샤드별 old_data(id<100000) vs new_data(id>=100000) 분포 비교
for pod in chi-chi-cluster1-0-0-0 chi-chi-cluster1-1-0-0 chi-chi-cluster1-2-0-0 chi-chi-cluster1-3-0-0; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT countIf(id<100000) AS old_data, countIf(id>=100000) AS new_data FROM events_local"
done
```

**실측 결과**:

| 샤드 | old_data (확장 전 데이터) | new_data (확장 후 삽입) |
|---|---|---|
| shard0 | 3034 (변화 없음) | 1040 |
| shard1 | 2958 (변화 없음) | 985 |
| shard2 | 3012 (변화 없음) | 1030 |
| shard3 (신규) | **0** | 945 |

새로 넣은 4000행은 4개 샤드에 고르게(~1000행씩) 분산됐지만, 확장 전부터 있던 9004행은
단 한 건도 shard3로 넘어오지 않고 원래 위치(shard0/1/2)에 그대로 남아 있습니다.

### 12-3. 수동 리샤딩: 기존 데이터 재분배

기존 데이터를 새 샤드로도 분산시키려면, ClickHouse에 내장된 자동 리샤딩 도구가 없으므로
**직접 재분배**해야 합니다. 표준적인 방법은 "`Distributed` 테이블을 통해 재삽입 →
원본에서 삭제"입니다.

```bash
# 1) shard0의 old_data 중 절반(id가 짝수인 것)을 Distributed 테이블로 재삽입
#    -> rand()가 다시 계산되어 4개 샤드 전체로 재분배됨
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
INSERT INTO events SELECT id, event_time, payload FROM events_local WHERE id < 100000 AND id % 2 = 0
"

# 2) 원본 shard0 테이블에서 방금 재삽입한 행 삭제 (mutation, 비동기 — system.mutations로 완료 확인)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
ALTER TABLE events_local DELETE WHERE id < 100000 AND id % 2 = 0
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SELECT count() FROM system.mutations WHERE table='events_local' AND is_done=0"   # 0이 될 때까지 대기

# 3) 결과 확인
for pod in chi-chi-cluster1-0-0-0 chi-chi-cluster1-1-0-0 chi-chi-cluster1-2-0-0 chi-chi-cluster1-3-0-0; do
  echo "--- $pod old_data ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SELECT count() FROM events_local WHERE id < 100000"
done
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"   # 총합 불변 확인
```

**실측 결과** (shard0의 1529건을 재분배 대상으로 선택):

| 샤드 | 리샤딩 전 old_data | 리샤딩 후 old_data |
|---|---|---|
| shard0 | 3034 | 1864 |
| shard1 | 2958 | 3365 |
| shard2 | 3012 | 3418 |
| shard3 | 0 | 357 |
| **합계** | **9004** | **9004** (불변) |

Distributed 총합도 13004로 리샤딩 전후 변화 없음 — 유실/중복 없이 재분배 성공.
흥미로운 디테일: shard0에서 1529건을 삭제했는데 실제 감소는 1170건뿐입니다. `rand()`는
재삽입 시 원본 샤드를 배제하지 않으므로, 재삽입된 행 중 일부(약 359건, 1529/4에 근접)가
**우연히 다시 shard0으로** 돌아왔기 때문입니다. 정확성(유실/중복 없음)은 보장되지만,
분배 효율은 완벽하지 않다는 점을 보여줍니다.

> ⚠️ **`shardsCount`를 다시 3으로 줄이지 마세요.** 오퍼레이터는 `shardsCount`를 줄이면
> 초과된 샤드(여기서는 shard3)의 파드와 PVC를 그대로 **삭제**합니다. 리샤딩으로 shard3에
> 실제 데이터(945+357건)가 들어간 상태이므로, 축소하면 그 데이터가 영구 유실됩니다.

### 12-4. 핵심 정리

- 샤드 추가는 **미래에 들어올 데이터**의 분산 범위만 넓힐 뿐, 과거 데이터는 그대로 둔다.
- 리샤딩은 "Distributed로 재삽입 + 원본에서 DELETE mutation" 조합으로 수동 수행하며,
  ClickHouse 자체 자동화 도구는 없다 (외부 도구로 `clickhouse-copier`류가 있었으나
  최신 버전에서는 사실상 이 수동 패턴이 표준).
- `rand()` 기반 재분배는 원본 샤드를 배제하지 않아 완벽하게 균등하지는 않다.
- `shardsCount`를 줄이는 축소 방향은 파괴적(데이터 유실)이므로 별도의 사전 마이그레이션
  없이는 수행하면 안 된다.

---

## 14. 무중단 롤링 업그레이드

CHI에 `podTemplate`으로 명시적 이미지 태그를 지정하면, 오퍼레이터가 태그 변경을 감지해
전체 클러스터를 순차적으로(rolling) 재기동합니다. `spec.configuration.clusters[].templates.podTemplate`로
클러스터 단위에 특정 파드 템플릿을 연결합니다.

```yaml
spec:
  configuration:
    clusters:
      - name: "cluster1"
        layout:
          shardsCount: 4
          replicasCount: 3
        templates:
          podTemplate: clickhouse-version   # 아래 템플릿을 이 클러스터에 연결
  templates:
    podTemplates:
      - name: clickhouse-version
        spec:
          containers:
            - name: clickhouse            # 오퍼레이터가 생성하는 컨테이너 이름과 일치해야 함
              image: clickhouse/clickhouse-server:26.8.2.7
```

### 13-1. ⚠️ 다운그레이드는 지원되지 않는다

처음에는 "구버전 → 신버전" 순서로 테스트하려고 `24.8`을 baseline으로 지정했는데,
이미 `26.8.2.7`로 가동 중이던 클러스터에 적용하자 해당 파드가 **CrashLoopBackOff**에
빠졌습니다.

```
DB::Exception: ... (INCORRECT_FILE_NAME) ... (ASYNC_LOAD_FAILED) ...
(version 24.8.14.39 (official build))
```

원인: `system.metric_log`(내부 시스템 테이블)의 파트가 이미 26.8이 쓴 최신 마크 파일
포맷으로 디스크에 저장돼 있는데, 24.8의 파서가 이 포맷을 모릅니다. **ClickHouse는
공식적으로 다운그레이드를 지원하지 않으며**, 한 번이라도 최신 포맷으로 데이터/메타데이터를
쓴 뒤에는 예전 바이너리로 되돌아갈 수 없습니다 — 온디스크 포맷은 전진(forward)만 가능한
편도 마이그레이션입니다.

**교훈**: 롤백 계획을 세울 때 "이전 이미지 태그로 되돌리면 된다"고 가정하지 말 것.
실제 롤백은 스냅샷/백업 복원이 필요합니다.

### 13-2. 실제 업그레이드 (26.8.2.7 → 26.9.1.510 `head`)

깨진 파드를 `26.8.2.7`(현재 떠 있던 버전을 `latest` 대신 명시적 태그로 고정)로 되돌려
베이스라인을 안정화한 뒤, 이 시점보다 새로운 버전이 Docker Hub에 따로 태깅되어 있지
않아 nightly 빌드인 `clickhouse/clickhouse-server:head`로 업그레이드했습니다.

```bash
# 베이스라인 적용 (12개 파드, 순차 롤링) 후 확정 대기
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get chi chi -w

# 이미지 태그를 head로 변경 후 재적용
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
```

**관찰**: 오퍼레이터는 12개 파드를 대부분 한 번에 1~2개씩 순차적으로 교체했고
(`ProgressHostsCompleted: N of 12` 이벤트로 진행 상황 확인 가능), 전체 롤아웃에
**약 55분** 소요됐습니다 (베이스라인 적용도 비슷하게 오래 걸림 — 이 랩 환경의 이미지
pull/헬스체크 주기가 지배적 요인으로 보이며, 실제 운영 클러스터의 소요 시간과는
무관합니다).

**최종 확인**:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT version()"
# => 26.9.1.510
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"
# => 13004 (유실 없음)
```

> **최신성 참고 (2026-09-14)**: 이 실험 이후 `manifests/chi.yaml`의 이미지 태그가
> `:head`(nightly, 계속 흘러가는 태그)로 남아있습니다. `:head`는 이후 계속 새
> 빌드를 받아왔고(지금 이 클러스터는 `26.9.1.872`), 이는 PRODUCTION.md
> 체크리스트가 명시적으로 금지하는 "`:head`/`:latest`로 프로덕션 운영 금지"
> 원칙을 이 랩 자신의 매니페스트가 어기고 있는 셈입니다. 재현 시에는 그 시점의
> 최신 stable 태그(예: 이 글 작성 시점 기준 `26.8.3.105`, GitHub Releases에서
> 확인 — `:head`가 아닌 고정 버전)로 바꿔서 배포하는 걸 권장합니다.

### 13-3. ⚠️ 가용성 프로브 방법론에 대한 교훈

롤아웃 동안 `kubectl port-forward svc/clickhouse-chi 18123:8123`를 열어두고 1초마다
`curl`로 쿼리를 반복하는 방식으로 가용성을 측정했는데, 업그레이드 시작 약 40초 후부터
**남은 30분 내내 연결이 복구되지 않았습니다** (355/409 요청 실패).

**진짜 원인**: `kubectl port-forward`는 Service 뒤의 **특정 파드 하나에 고정**됩니다.
그 파드가 롤링 재시작으로 죽자 터널이 끊겼고, kubectl은 다른 살아있는 파드로
자동 재연결하지 않습니다 (프로세스를 새로 띄워야 함). 즉 이 "다운타임"은 **클러스터의
실제 가용성이 아니라 `port-forward`의 알려진 한계**를 측정한 것입니다.

**올바른 측정 방법**: (1) 재시작 대상이 아닌 안정적인 파드에서 `kubectl exec`로 반복
쿼리하거나, (2) 매 요청마다 새로 연결하는(reconnect) 클라이언트를 쓰거나, (3) 실제
운영에서는 커넥션 풀 + 재시도 로직이 있는 드라이버를 사용해야 합니다. 7-1절/10절의
장애 실험에서 `kubectl exec` 기반으로 측정했을 때는 Distributed 테이블이 개별 레플리카
장애를 정상적으로 우회했음을 이미 확인한 바 있습니다 — 롤링 업그레이드도 동일하게
레플리카 단위로 순차 진행되므로, 같은 방식(안정된 파드에서 exec)으로 다시 측정하면
실제 다운타임은 훨씬 낮을 것으로 예상됩니다. (이번 세션에서는 시간 관계상 재측정하지
않음 — 다음 실험 후보로 남겨둠.)

### 13-4. 핵심 정리

| 항목 | 결과 |
|---|---|
| 다운그레이드 (26.8→24.8) | 실패 (CrashLoopBackOff) — 온디스크 포맷 비호환, 공식 미지원 |
| 업그레이드 (26.8.2.7→26.9.1.510) | 성공, 데이터 유실 없음 (13004행 그대로) |
| 롤아웃 방식 | 순차적 (1~2개씩), 12파드에 약 55분 |
| 가용성 측정 | `port-forward` 기반 측정은 신뢰 불가 (파드 고정 문제) — `exec` 기반 재측정 필요 |

---

## 15. 부하 테스트 & `max_parallel_replicas` 실험

`max_parallel_replicas`는 **같은 샤드 안의 여러 레플리카**가 하나의 쿼리를 나눠서 함께
스캔하게 만드는 설정입니다(레플리카를 "여분"이 아니라 "추가 연산력"으로 활용). 실제
효과가 있는지 `clickhouse-benchmark`로 직접 측정합니다.

### 14-1. 벤치마크용 데이터셋 준비

기존 `events` 테이블(13,004행)은 스캔이 거의 즉시 끝나 병렬화 효과를 볼 수 없으므로,
스캔 부하가 확실히 걸리는 별도 테이블에 1,000만 행을 새로 적재합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE bench_local ON CLUSTER 'cluster1'
(
    id UInt64,
    category LowCardinality(String),
    val1 Float64,
    val2 Float64,
    payload String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/bench_local', '{replica}')
ORDER BY id
"

kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE bench ON CLUSTER 'cluster1' AS bench_local
ENGINE = Distributed('cluster1', currentDatabase(), bench_local, rand())
"

kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client --max_insert_threads=4 -q "
INSERT INTO bench
SELECT
    number AS id,
    ['electronics','books','clothing','toys','food','sports','tools','music'][(number % 8) + 1] AS category,
    sin(number) * 1000 AS val1,
    cos(number) * 1000 AS val2,
    hex(number) || repeat('x', 40) AS payload
FROM numbers(10000000)
"
```

결과: 4샤드에 걸쳐 총 1,000만 행(샤드당 약 250만 행), 압축 후 샤드당 디스크 사용량은
약 62MB — 2Gi PVC 대비 여유롭습니다.

### 14-2. `enable_parallel_replicas` — 이 버전(26.9)의 실제 설정 이름

이 버전에서 `max_parallel_replicas`는 **기본값이 이미 1000**입니다. 하지만 실제로
병렬 읽기를 켜는 스위치는 `enable_parallel_replicas`(과거 이름
`allow_experimental_parallel_reading_from_replicas`)이고 기본값은 `0`(꺼짐)입니다.
즉 `max_parallel_replicas`만 지정해서는 아무 효과가 없고, 반드시
`enable_parallel_replicas=1`을 함께 켜야 합니다.

```sql
SELECT name, value, description FROM system.settings WHERE name ILIKE '%parallel_replicas%'
```

**주의할 함정**: 로컬 테이블(`bench_local`)에 직접 이 설정을 걸면 다음 에러가 납니다.

```
Code: 701. Reading in parallel from replicas is enabled but cluster to execute
query is not provided. Please set 'cluster_for_parallel_replicas' setting.
```

그런데 `cluster_for_parallel_replicas='cluster1'`을 지정하면 또 다른 에러가 납니다.

```
Code: 714. `cluster_for_parallel_replicas` setting refers to cluster with 4
shards. Expected a cluster with one shard.
```

`cluster_for_parallel_replicas`는 **샤드 1개짜리** 클러스터 정의(그 샤드의 레플리카들만
나열)를 기대하는데, 우리 `cluster1`은 4샤드짜리라 쓸 수 없습니다. 해결책은 **Distributed
테이블(`bench`)에 대고 쿼리하는 것** — Distributed 엔진이 이미 `cluster1`을 알고 있으므로
`cluster_for_parallel_replicas` 없이 `enable_parallel_replicas=1`, `max_parallel_replicas=3`
만 지정하면 됩니다. 그러면 각 샤드로의 팬아웃 각각이 자기 샤드 안의 3개 레플리카로
다시 병렬화됩니다.

```sql
SELECT category, count(), avg(val1), avg(val2), sum(length(payload))
FROM bench WHERE val1 > 0 GROUP BY category
SETTINGS enable_parallel_replicas=1, max_parallel_replicas=3
```

### 14-3. 병렬 읽기가 실제로 발동했는지 증거로 확인

`system.query_log`는 노드별 로컬 로그라, 같은 `initial_query_id`로 각 노드에 몇 개의
서브쿼리 로그가 남았는지 세어보면 어느 레플리카가 실제로 일을 했는지 알 수 있습니다.

```bash
for pod in chi-chi-cluster1-0-0-0 chi-chi-cluster1-0-1-0 chi-chi-cluster1-0-2-0; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SYSTEM FLUSH LOGS"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT count() FROM system.query_log WHERE initial_query_id='<쿼리ID>'"
done
```

**실측 결과**: 샤드0의 나머지 두 레플리카(`0-1`, `0-2`)에도 각각 2건씩 로그가 남아있어,
평소라면 초기화 쿼리를 실행한 `0-0` 혼자 처리했을 일을 실제로 3개 레플리카가 나눠서
처리했음을 확인했습니다. **기능 자체는 정상 작동합니다.**

### 14-4. 성능 비교 — 그러나 오히려 느려짐

```bash
# 기본(병렬 없음)
clickhouse-benchmark -i 60 -c 2 --query "SELECT category, count(), avg(val1), avg(val2), sum(length(payload)) FROM bench WHERE val1 > 0 GROUP BY category"

# enable_parallel_replicas=1, max_parallel_replicas=3
clickhouse-benchmark -i 60 -c 2 --query "... SETTINGS enable_parallel_replicas=1, max_parallel_replicas=3"
```

| 설정 | QPS | p50 | p90 | p99 |
|---|---|---|---|---|
| 기본 (병렬 없음) | 18.43 | 96ms | 138ms | 206ms |
| `enable_parallel_replicas=1`, `max_parallel_replicas=3` | 14.01 | 132ms | 154ms | 190ms |

동시성을 8로 올리고 쿼리를 더 무겁게(`uniqExact` 추가)해서 재측정해도 같은 경향이
재현됩니다.

| 설정 (동시성 8, 무거운 쿼리) | QPS | p50 | p99 |
|---|---|---|---|
| 기본 | 10.84 | 717ms | 1319ms |
| 병렬 레플리카 ON | 7.64 | 1050ms | 1437ms |

**결론: 이 환경에서는 `max_parallel_replicas`가 오히려 성능을 떨어뜨립니다.** 억지로
긍정적 결과를 만들지 않고 있는 그대로 보고합니다. 원인으로 추정되는 것:

1. **데이터 규모가 너무 작음** — 레플리카 1개가 담당하는 몫이 샤드당 250만 행(약
   15MB 압축 컬럼)뿐이라, 단일 스레드로도 100ms 안팎이면 끝남. 병렬화로 아낄 수 있는
   시간보다 레플리카 간 작업 분배·결과 병합에 드는 **조율 오버헤드**가 더 큼.
2. **레플리카들이 진짜 별도 하드웨어가 아님** — 이 랩의 12개 ClickHouse 파드는 모두
   `kind` 워커 노드(컨테이너)이고, 그 워커 노드들은 결국 **하나의 Colima VM(6 vCPU)**을
   나눠 쓰고 있습니다. 즉 "병렬" 레플리카가 실제로는 같은 물리 코어를 두고 경쟁하는
   셈이라, 진짜 멀티노드 클러스터에서 기대할 수 있는 병렬 처리 이득이 나타나지 않습니다.

`max_parallel_replicas`는 **레플리카당 스캔량이 충분히 크고(수억~수십억 행), 레플리카가
실제로 분리된 하드웨어/코어를 가진** 상황에서 의미가 있는 기능이며, 이런 로컬 랩
환경에서 검증하기에는 태생적으로 불리한 실험이라는 점이 이번 실험의 정직한 결론입니다.

### 14-5. 정리

실험 전용 테이블은 이후 실험에 재사용하지 않으므로 삭제해 PVC 공간을 반환했습니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "DROP TABLE IF EXISTS bench ON CLUSTER 'cluster1' SYNC"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "DROP TABLE IF EXISTS bench_local ON CLUSTER 'cluster1' SYNC"
```

---

## 16. Mutation & TTL 라이프사이클

`ALTER TABLE ... UPDATE/DELETE`(mutation)와 TTL 만료가 `ReplicatedMergeTree` 클러스터
전체에 어떻게 전파되는지, 그리고 TTL이 "시간이 되면 즉시" 지워지는 게 아니라
**병합(merge) 시점에만 평가**된다는 사실을 직접 확인합니다.

### 15-1. Mutation 전파 (비동기 vs 동기)

```bash
# 비동기(기본값) UPDATE — 즉시 리턴, 백그라운드에서 진행
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' UPDATE payload = concat('updated-', toString(id)) WHERE id % 3 = 0
"

# system.mutations를 폴링하며 진행 상황 관찰 (모든 파드에서 is_done=1 될 때까지)
for pod in chi-chi-cluster1-{0,1,2,3}-{0,1,2}-0; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT count() FROM system.mutations WHERE table='events_local' AND NOT is_done"
done

# 동기(mutations_sync=2) UPDATE — 클러스터 전체 완료까지 클라이언트가 블로킹
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' UPDATE payload = concat('updated2-', toString(id)) WHERE id % 3 = 1
SETTINGS mutations_sync=2
"

# DELETE도 동일하게 mutation 큐를 거침 (즉시 삭제가 아님)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' DELETE WHERE id % 3 = 2
"
```

**확인된 결과**: 3개 mutation(`UPDATE` 비동기, `UPDATE ... SETTINGS mutations_sync=2`,
`DELETE`) 모두 `system.mutations.is_done=1`로 12개 파드 전체에서 완료됨을 확인했습니다.
`mutations_sync=2`는 클라이언트 명령 자체가 클러스터 전체 완료까지 블로킹된다는 점이
비동기 방식(명령은 즉시 리턴하고 `system.mutations`를 폴링해서 완료를 확인)과 다릅니다.
DELETE 후 `SELECT count() FROM events`는 8670행으로, 삭제 대상(`id % 3 = 2`)만큼
정확히 줄어든 것을 확인했습니다.

### 15-2. TTL은 "시간이 되면 자동으로" 지워지지 않는다

TTL 만료는 **백그라운드 병합이 그 파트를 건드릴 때만** 평가됩니다. 계속 스캔하며
지우는 별도 프로세스가 있는 게 아닙니다. 이를 명확히 보려고 실제 서비스 데이터
(`events`/`events_local`, 며칠에 걸쳐 삽입된 `event_time` 값들)를 건드리지 않고
전용 테스트 테이블로 시연했습니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE ttl_demo_local ON CLUSTER 'cluster1'
(
    id UInt64,
    inserted_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/ttl_demo_local', '{replica}')
ORDER BY id
TTL inserted_at + INTERVAL 30 SECOND
"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
CREATE TABLE ttl_demo ON CLUSTER 'cluster1' AS ttl_demo_local
ENGINE = Distributed('cluster1', currentDatabase(), ttl_demo_local, rand())
"

# 이미 TTL 기준(30초)을 넘겨 "만료된 채로" 태어나는 행 4개 + 방금 삽입된 신선한 행 1개
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "
INSERT INTO ttl_demo_local VALUES
  (1, now() - INTERVAL 1 MINUTE), (2, now() - INTERVAL 1 MINUTE),
  (3, now() - INTERVAL 1 MINUTE), (4, now() - INTERVAL 1 MINUTE),
  (5, now())
"
```

30초는 물론이고 **10분 넘게 기다려도** 만료된 4개 행이 그대로 남아있었습니다 — 파트가
1개뿐이라 배경 병합이 일어날 대상이 없었기 때문입니다. `OPTIMIZE TABLE ... FINAL`을
실행해도 사라지지 않는 걸 추가로 확인했는데, 이는 ClickHouse가 파티션에 파트가
이미 1개뿐이면 "이미 최적화됨"으로 보고 실제 재작성(및 그에 딸린 TTL 재평가)을
건너뛰기 때문입니다(`optimize_skip_merged_partitions` 기본 동작). TTL을 확실히 강제
평가하려면 `ALTER TABLE ... MATERIALIZE TTL`을 써야 합니다:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "ALTER TABLE ttl_demo_local ON CLUSTER 'cluster1' MATERIALIZE TTL"

# system.mutations로 완료 확인 (이것도 mutation 큐를 거침)
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "SELECT is_done, parts_to_do FROM system.mutations WHERE table='ttl_demo_local'"

kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT * FROM ttl_demo_local ORDER BY inserted_at"
```

**실측 결과**: `MATERIALIZE TTL` 실행 후 `is_done=1`로 완료되자마자, 만료됐던 4개 행은
사라지고 신선한 행만 남았습니다(파트가 `rows=0`으로 재작성됨). 즉:

- TTL은 "만료 시각이 지나면 즉시" 적용되는 게 아니라, **병합(또는 `MATERIALIZE TTL`
  mutation)이 그 데이터를 실제로 건드릴 때** 비로소 적용됩니다.
- 파트가 이미 1개뿐인 작은 테이블에서는 `OPTIMIZE ... FINAL`조차 지름길로 판단되어
  아무 일도 하지 않을 수 있습니다 — 이럴 땐 `MATERIALIZE TTL`이 확실한 방법입니다.
- 실서비스에서 배경 병합이 자주 도는 큰 테이블은 이런 지연이 몇 분~병합 주기 안에
  자연스럽게 해소되지만, 삽입이 뜸한 작은 테이블/파티션에서는 만료된 데이터가
  예상보다 훨씬 오래(관찰상 10분 이상) 남아있을 수 있다는 점을 실무에서 유의해야
  합니다.

### 15-3. 정리

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "DROP TABLE IF EXISTS ttl_demo ON CLUSTER 'cluster1' SYNC"
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "DROP TABLE IF EXISTS ttl_demo_local ON CLUSTER 'cluster1' SYNC"
```

### 15-4. 핵심 정리

| 항목 | 결과 |
|---|---|
| 비동기 mutation | 명령 즉시 리턴, `system.mutations.is_done`을 폴링해 완료 확인 (12개 파드 전체 확인) |
| 동기 mutation (`mutations_sync=2`) | 클라이언트가 클러스터 전체 완료까지 블로킹 |
| DELETE mutation | 동일하게 mutation 큐 경유, 즉시 삭제 아님 |
| TTL 만료 트리거 | 오직 병합(또는 `MATERIALIZE TTL`) 시점에만 평가 — 시간 경과만으로는 지워지지 않음 |
| 단일 파트 테이블의 함정 | `OPTIMIZE ... FINAL`도 건너뛸 수 있음 → `MATERIALIZE TTL`이 확실한 강제 수단 |

---

## 17. 네트워크 파티션 (스플릿 브레인) 시뮬레이션

> ⚠️ **이 실험은 지금까지 중 가장 리스크가 높습니다.** 노드 레벨에서 iptables 규칙을
> 직접 조작하므로, 규칙을 걷어내는 명령을 미리 적어두고 파티션 유지 시간을 짧게
> (수십 초 단위) 제한한 뒤 곧바로 원복 → 연결 확인 → 클러스터 헬스체크까지 마친
> 다음에야 분석/기록으로 넘어가는 규율을 지켰습니다. kind 클러스터가 아닌 실제
> 운영 환경에서는 훨씬 신중하게, 가능하면 카오스 엔지니어링 전용 도구(Chaos Mesh
> 등)로 하시길 권합니다.

10절("Keeper 노드 장애 내성 테스트")은 `SYSTEM STOP MERGES` 대신 파드를 아예
0으로 스케일해 Keeper 프로세스 자체를 죽이는 방식이었습니다. 이번엔 **프로세스는
살아있는 채로 네트워크만 끊어서**, Keeper의 Raft 합의가 진짜 스플릿 브레인
상황에서 어떻게 동작하는지 — 그리고 파티션이 풀렸을 때 10절과 달리 **사람이 개입할
필요 없이 저절로 재합류**하는지를 확인합니다.

### 16-1. 왜 `NetworkPolicy`가 아니라 `iptables`인가

kind의 기본 CNI인 kindnet은 Kubernetes `NetworkPolicy` 오브젝트를 지원하지
않습니다. 대신 kind의 각 노드는 그 자체로 하나의 Docker 컨테이너이자 독립된
Linux 네트워크 네임스페이스이므로, **노드 컨테이너 안에서 직접 `iptables`
규칙을 걸면 그 노드를 오가는 파드 트래픽을 실제로 차단**할 수 있습니다
(kindest/node 이미지에는 kube-proxy가 쓰는 `iptables`가 이미 포함돼 있습니다).

### 16-2. 토폴로지 확인 — 딱 맞는 2:1 분할이 가능한 배치

```bash
kubectl --context kind-clickhouse-lab -n clickhouse get pods -o wide | grep keeper
kubectl --context kind-clickhouse-lab get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

Keeper 3개 파드가 마침 `chk-chk-keeper-0-0`/`-0-1`은 `worker2`(파드 CIDR
`10.244.3.0/24`)에, `chk-chk-keeper-0-2`는 `worker3`(`10.244.1.0/24`)에
떠 있었습니다. 두 노드 사이의 파드 트래픽만 막으면 자연스럽게 **다수파
2개(0-0, 0-1) vs 소수파 1개(0-2)**로 갈라집니다.

### 16-3. 파티션 적용 → 관찰 → 즉시 원복 (전체 12초 안에)

```bash
# 제거 명령을 미리 적어둔 뒤 적용 (양방향, 양쪽 노드 모두)
docker exec clickhouse-lab-worker2 iptables -I FORWARD -s 10.244.1.0/24 -d 10.244.3.0/24 -j DROP
docker exec clickhouse-lab-worker2 iptables -I FORWARD -s 10.244.3.0/24 -d 10.244.1.0/24 -j DROP
docker exec clickhouse-lab-worker3 iptables -I FORWARD -s 10.244.3.0/24 -d 10.244.1.0/24 -j DROP
docker exec clickhouse-lab-worker3 iptables -I FORWARD -s 10.244.1.0/24 -d 10.244.3.0/24 -j DROP

# 실제로 끊겼는지 확인 (타임아웃이 나야 정상)
kubectl --context kind-clickhouse-lab -n clickhouse exec chk-chk-keeper-0-2-0 -- sh -c "nc -zv -w2 10.244.3.20 2181"

# 양쪽의 Keeper 4-letter-word 상태 확인 (ZooKeeper와 동일한 mntr 인터페이스)
kubectl --context kind-clickhouse-lab -n clickhouse exec chk-chk-keeper-0-0-0 -- sh -c "echo mntr | nc -w2 127.0.0.1 2181"
kubectl --context kind-clickhouse-lab -n clickhouse exec chk-chk-keeper-0-2-0 -- sh -c "echo mntr | nc -w2 127.0.0.1 2181"

# 다수파를 거쳐 쓰기가 되는지 확인
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q \
  "INSERT INTO events_local VALUES (999001, now(), 'partition-test-majority')"

# 곧바로 규칙 제거
docker exec clickhouse-lab-worker2 iptables -D FORWARD -s 10.244.1.0/24 -d 10.244.3.0/24 -j DROP
docker exec clickhouse-lab-worker2 iptables -D FORWARD -s 10.244.3.0/24 -d 10.244.1.0/24 -j DROP
docker exec clickhouse-lab-worker3 iptables -D FORWARD -s 10.244.3.0/24 -d 10.244.1.0/24 -j DROP
docker exec clickhouse-lab-worker3 iptables -D FORWARD -s 10.244.1.0/24 -d 10.244.3.0/24 -j DROP
```

**실측 결과 (예상과 다르게 흥미로웠던 지점)**: 파티션을 걸기 직전 우연히
**리더가 소수파 쪽(`keeper-0-2`)**에 있었습니다. 파티션 후 12초라는 짧은
관찰 창 안에서:

- 다수파(`keeper-0-0`, `keeper-0-1`)는 `mntr`이 `"This instance is not
  currently serving requests"`를 반환 — 리더를 잃고 새 리더를 선출하는
  중이라 아직 요청을 못 받는 상태.
- 소수파(`keeper-0-2`)는 여전히 `zk_server_state: leader`, `zk_followers: 2`,
  `zk_synced_followers: 2`로 자기 자신을 정상 리더라고 보고 — 팔로워 단절을
  아직 감지하지 못한 찰나의 "가짜 리더" 상태였습니다(하트비트 타임아웃이
  아직 안 지났기 때문으로 추정).
- 그럼에도 `chi-chi-cluster1-0-0-0`(파티션에 걸리지 않은 `worker` 노드)을
  통한 쓰기는 **성공**했습니다.

즉, 명확하게 "다수파만 쓰기 가능, 소수파는 즉시 실패"라는 교과서적인 결과가
아니라, **선출 유예(election grace period) 동안에는 경계가 순간적으로
모호할 수 있다**는 걸 있는 그대로 확인했습니다. 파티션이 조금이라도 더 길게
지속됐다면 소수파도 곧 팔로워 감지 타임아웃에 걸려 리더 자격을 잃었을
것입니다.

### 16-4. 원복 후 자동 자가치유 확인 (핵심 발견)

```bash
# 연결 복구 확인
kubectl --context kind-clickhouse-lab -n clickhouse exec chk-chk-keeper-0-2-0 -- sh -c "nc -zv -w2 10.244.3.20 2181"

# 모든 keeper의 상태를 다시 확인 — 수동 개입 없이 자동으로 정리됐는지
for pod in chk-chk-keeper-0-0-0 chk-chk-keeper-0-1-0 chk-chk-keeper-0-2-0; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- sh -c "echo mntr | nc -w2 127.0.0.1 2181" | grep zk_server_state
done
```

**결과**: 규칙 제거 후 곧바로(5초 대기 후 확인) — `keeper-0-0`이 새 리더로
정착(`zk_followers: 2`, `zk_synced_followers: 2`), `keeper-0-1`과 예전에
"가짜 리더"였던 `keeper-0-2`는 둘 다 자연스럽게 `follower`로 안착했습니다.
**아무 명령도 실행하지 않았는데** 3노드 Raft 앙상블이 스스로 재합류한
것입니다.

이는 10절의 "파드를 0으로 스케일"(=프로세스 자체가 사라짐) 실험과 명확히
대비됩니다:

| | 10절: 파드 스케일 0 (프로세스 종료) | 16절: 네트워크 파티션 (프로세스는 생존) |
|---|---|---|
| 장애 유형 | 프로세스/디스크 상태 소실 가능 | 통신만 두절, 로컬 상태는 그대로 |
| 복구에 필요한 것 | 파드 재생성(자동) + 필요 시 수동 재등록 | **아무것도 필요 없음** — Raft가 스스로 재합류 |
| 소수파의 착각 가능성 | 없음(그냥 죽어 있음) | 있음 — 짧은 창에서 "가짜 리더" 상태 관찰됨 |

### 16-5. 사후 검증 및 정리

파티션/복구 전 과정에서 클러스터가 완전히 정상인지 최종 확인:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM system.clusters WHERE cluster='cluster1'"   # 12
kubectl --context kind-clickhouse-lab -n clickhouse exec chi-chi-cluster1-0-0-0 -- clickhouse-client -q "SELECT count() FROM events"   # 8671 (기존 8670 + 파티션 중 쓴 테스트 행 1개)
```

테스트 중 삽입한 `id=999001` 행은 "파티션 중 다수파를 통한 쓰기가 실제로
유실 없이 살아남았다"는 증거로 그대로 남겨뒀습니다 (`payload =
'partition-test-majority'`로 식별 가능).

### 16-6. 핵심 정리

| 항목 | 결과 |
|---|---|
| 파티션 도구 | kind 노드 컨테이너 안에서 `iptables FORWARD` 규칙 (kindnet은 `NetworkPolicy` 미지원) |
| 분할 | Keeper 2(다수) vs 1(소수), 노드 배치를 이용해 깔끔하게 분리 |
| 관찰 창 | 총 12초 (안전을 위해 최소화) |
| 소수파 동작 | 짧은 창에서는 "가짜 리더" 상태가 관찰될 수 있음 (하트비트 타임아웃 전) |
| 다수파 쓰기 | 성공 (데이터 유실 없음) |
| 파티션 해제 후 | **수동 개입 없이** Raft가 자동으로 재합류 — 10절(프로세스 종료)과의 핵심 차이 |
| 데이터 정합성 | `system.clusters` 12, `events` 8671행으로 최종 정상 확인 |

---

## 18. 접속 (호스트에서 직접 붙어보기)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/clickhouse-chi 8123:8123 9000:9000
# 다른 터미널에서
clickhouse-client --host 127.0.0.1
# 또는
curl 'http://localhost:8123/?query=SELECT%201'
```

---

## 19. 백업/복구 실전 훈련 (재해복구 드릴)

지금까지의 장애 실험은 전부 "클러스터 안에서 자동/수동 복구"였습니다. 이번엔 **클러스터
자체가 통째로 날아갔을 때 처음부터 복원**하는, 진짜 재해복구(DR) 드릴을 해봤습니다.
14절에서 "다운그레이드는 불가능하니 롤백은 스냅샷/백업 복원이 필요하다"고 써두고도
실제로 백업/복구를 검증한 적이 없었던 공백을 메우는 실험입니다.

### 19-1. 백업 대상: MinIO(S3 호환)

ClickHouse 22.8+에 내장된 `BACKUP`/`RESTORE` SQL 문을 씁니다. 백업 목적지는 각 Pod의
PVC와 독립적이어야 진짜 재해(전체 유실)에서도 살아남으므로, S3 호환 오브젝트 스토리지가
필요합니다. 이 랩엔 실제 S3가 없으므로 MinIO를 배포해 대신합니다.

```yaml
# manifests/minio.yaml (요약)
image: quay.io/minio/minio:latest   # docker.io/minio/minio는 더 이상 pull 불가 (Docker Hub에서 내려감)
args: [server, /data, --console-address, ":9090"]
```

> **겪은 함정**: `minio/minio:latest`(Docker Hub)가 `pull access denied`로 실패했습니다.
> 처음엔 단순히 "Docker Hub 배포를 접고 `quay.io`로 이전했다"고만 기록했는데,
> **2026-09-14 재확인 결과 훨씬 심각한 상황**이었습니다 — MinIO는 2026-04-25에
> GitHub 저장소 자체를 **archived(유지보수 종료) 처리**했고, Docker Hub 이미지
> 제거는 그 결과물 중 하나일 뿐입니다. Community Edition은 이제 신규 릴리스/
> 보안 패치가 나오지 않고, 회사는 유료 상용 제품("AIStor")으로 사용자를 유도하는
> 중입니다. **이 랩에서는 "재해복구 실습용 S3 목적지"라는 국한된 용도로만 계속
> 쓰지만, 실제 프로덕션 백업 목적지로는 진짜 클라우드 S3(또는 여전히 활발히
> 유지보수되는 다른 S3 호환 스토리지)를 쓰고, 이미 MinIO를 쓰고 있다면 이관
> 계획을 세우세요.**

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/minio.yaml
# mc(MinIO 클라이언트)로 버킷 생성
kubectl --context kind-clickhouse-lab -n clickhouse run mc-setup --rm -i --restart=Never \
  --image=quay.io/minio/mc:latest --command -- sh -c "
  mc alias set myminio http://minio.clickhouse.svc.cluster.local:9000 clickhouse-backup clickhouse-backup-secret &&
  mc mb myminio/ch-backups"
```

> 이 랩의 MinIO는 `emptyDir`을 씁니다 — MinIO Pod 자체가 재시작되면 백업도 함께
> 사라집니다. 실제 운영에서는 반드시 진짜 S3(또는 PVC 기반 MinIO)를 써야 합니다.

### 19-2. 처음 겪은 함정: `ON CLUSTER` 없이 백업하면 샤드 1개분만 조용히 백업된다

`push_click` 데이터베이스(고객 7명, 발송 244건, 클릭 5건 — 4샤드에 `cityHash64`로
분산된 실제 앱 데이터)를 첫 시도에서 이렇게 백업했습니다.

```sql
BACKUP DATABASE push_click TO S3('http://minio.../ch-backups/backup_1', 'clickhouse-backup', 'clickhouse-backup-secret')
-- BACKUP_CREATED, num_files=105 (성공! 에러 없음)
```

**에러 없이 성공했지만, 이 백업은 실행한 그 노드(샤드1/레플리카1) 하나의 로컬 데이터만
담고 있었습니다.** `DROP DATABASE push_click`(역시 `ON CLUSTER` 없이) 후
`RESTORE DATABASE push_click FROM S3(...)`를 실행하자 복구는 "성공"했다고 나왔지만,
Distributed 테이블로 조회하니:

```
Code: 279. DB::Exception: All connection tries failed.
There is no table `push_click`.`click_stats_local` on server: chi-chi-cluster1-2-0:9000
```

샤드2/3/4에는 테이블 자체가 아예 존재하지 않았습니다 — 데이터 누락이 아니라 **스키마
자체가 그 3개 샤드에는 없었습니다.** `BACKUP`/`RESTORE DATABASE`는 `ON CLUSTER` 없이는
**실행한 그 노드 하나**에서만 동작하는 순수 로컬 명령이기 때문입니다(다른 DDL과 동일한
규칙). 문제를 바로잡으려고 `DROP DATABASE push_click ON CLUSTER 'cluster1'`로 제대로
지운 시점에는 이미 샤드2/3/4의 **원본 데이터**(애초에 한 번도 백업된 적 없던)가 함께
삭제되어, 결과적으로 이 랩의 데모 데이터를 실제로 잃어버렸습니다(합성 테스트 데이터라
`001_init.sql` 재적용 + 동일한 행 수로 재삽입해 복구했습니다).

**이 자체가 이번 실험의 핵심 교훈입니다**: `BACKUP DATABASE`가 에러 없이 성공했다는
사실은 "전체가 백업됐다"를 보장하지 않습니다. 샤드로 분산된 클러스터에서 이 함정은
**실제 재해 상황에서, 가장 발견하기 나쁜 시점에** 드러납니다.

### 19-3. 올바른 방법: `ON CLUSTER`로 백업/복구

```sql
BACKUP DATABASE push_click ON CLUSTER 'cluster1'
  TO S3('http://minio.clickhouse.svc.cluster.local:9000/ch-backups/push_click_backup_correct',
        'clickhouse-backup', 'clickhouse-backup-secret')
-- BACKUP_CREATED, num_files=717 (앞서의 105개와 대조적으로, 12개 노드 전체가 포함됨)
```

진짜 재해 시뮬레이션(클러스터 전체에서 완전 삭제 후 복구):

```sql
DROP DATABASE push_click ON CLUSTER 'cluster1' SYNC;
-- 4개 샤드 대표 노드 전부에서 EXISTS DATABASE push_click = 0 확인

RESTORE DATABASE push_click ON CLUSTER 'cluster1'
  FROM S3('http://minio.../ch-backups/push_click_backup_correct', ...)
-- RESTORED, 1.68초 소요
```

**검증 결과**: 4개 샤드 전부에 스키마 재생성 확인, Distributed 테이블 집계값이 재해
전과 정확히 일치(`customers=7, pushes=244, clicks=5`), MV/JOIN 뷰
(`campaign_realtime_stats`)도 정상 동작, 복구 직후 새 INSERT도 즉시 정상 반영 —
완전히 살아있는 클러스터로 복원됨을 확인했습니다.

### 19-4. 핵심 정리

| 항목 | 결과 |
|---|---|
| `BACKUP`/`RESTORE DATABASE` (ON CLUSTER 없이) | **위험** — 실행한 노드 하나만 백업/복구, 에러 없이 조용히 불완전 |
| `BACKUP`/`RESTORE DATABASE ... ON CLUSTER 'cluster1'` | 12개 노드 전체 포함 (105개 → 717개 파일로 확인) |
| 백업 목적지 | 클러스터 PVC와 독립된 저장소(S3/MinIO) 필수 — 로컬 디스크 백업은 "진짜 전체 유실" 시나리오에 무용 |
| RTO (이 데이터 규모 기준) | 백업 <1초, 복구 1.68초 (실제 프로덕션 데이터 규모에서는 훨씬 김 — 규모별 재측정 필요) |
| 복구 후 데이터 무결성 | 행 수 정확히 일치, MV/집계 뷰 정상, 신규 쓰기 즉시 반영 |

**운영 체크리스트에 추가할 것**: 백업 스크립트에 `ON CLUSTER`가 빠지면 매번 "성공"
로그만 남고 실제로는 샤드 1개분만 백업되는 것을 알아챌 방법이 없습니다. 정기적으로
**실제 복구 훈련**(백업만 하고 끝내지 않고, 다른 이름의 DB로 실제 RESTORE까지 해서
행 수를 비교)을 하지 않으면 이 사일런트 실패를 재해 당일까지 모를 수 있습니다.

---

## 20. 쿼리 자원 통제/거버넌스

여러 워크로드가 같은 클러스터를 공유할 때, 쿼리 하나가 전체에 영향을 주지 않도록 막는
장치들을 실제로 걸어보고 동작을 확인합니다.

### 20-1. `max_memory_usage` — 쿼리 하나가 쓸 수 있는 메모리 상한

```sql
SELECT count() FROM numbers(200000000) GROUP BY number % 1000000 SETTINGS max_memory_usage=10000000
```
```
Code: 241. DB::Exception: Query memory limit exceeded: would use 12.19 MiB
(attempt to allocate chunk of 4.03 MiB), maximum: 9.54 MiB (MEMORY_LIMIT_EXCEEDED)
```
정확히 설정한 한도에서 즉시, 깔끔한 예외로 종료됩니다.

### 20-2. `max_execution_time` — 실행 시간 상한

```sql
SELECT count() FROM numbers(50000000000) WHERE number % 7 = 0 SETTINGS max_execution_time=3
```
```
Code: 159. DB::Exception: Timeout exceeded: elapsed 3000.040 ms, maximum: 3000.000 ms (TIMEOUT_EXCEEDED)
```
설정한 3초에 정확히 맞춰 종료됩니다.

### 20-3. `KILL QUERY` — 다른 세션에서 실행 중인 쿼리 강제 종료

```sql
-- 세션 A: 오래 걸리는 쿼리 실행 (max_execution_time=0으로 자체 타임아웃 무력화)
SELECT count() FROM numbers(50000000000) WHERE number % 13 = 0 SETTINGS max_execution_time=0

-- 세션 B: system.processes로 찾아서 강제 종료
KILL QUERY WHERE query LIKE '%number %% 13%' SYNC
```
세션 A는 `Code: 394 QUERY_WAS_CANCELLED`로 즉시 종료됩니다 — 운영 중 폭주하는 쿼리를
사람이 개입해 안전하게 끊을 수 있음을 확인했습니다.

### 20-4. `max_concurrent_queries_for_user` — 사용자별 동시 쿼리 수 제한

```bash
# 동일 사용자로 3개 동시 실행, 한도는 2
for i in 1 2 3; do
  clickhouse-client -q "SELECT sleep(3), $i SETTINGS max_concurrent_queries_for_user=2" &
done
```
3번째 쿼리만 즉시 거부됩니다:
```
Code: 202. DB::Exception: Too many simultaneous queries for user default. Current: 2, maximum: 2.
```

### 20-5. `QUOTA` — 시간 단위 쿼리 횟수 제한, 그리고 겪은 함정

```sql
CREATE QUOTA test_quota KEYED BY user_name FOR INTERVAL 1 MINUTE MAX queries = 2 TO default
```

**처음엔 4번을 연달아 실행해도 전혀 막히지 않았습니다** — `system.quotas_usage`도
계속 `queries=0`으로 나왔습니다. 원인은 `SYSTEM RELOAD USERS`를 실행하지 않아서였습니다.
`default` 사용자가 `users.xml`(정적 설정 파일) 기반이라, SQL로 새로 만든 쿼터가 그
사용자에게 실제로 적용되기까지 접근 제어 재적재가 필요했습니다. `SYSTEM RELOAD USERS`
실행 후에는 정확히 한도(2)에서 막혔고, 심지어 **한도를 초과한 뒤에는 그 쿼터를 고치려는
`DROP QUOTA`/`SYSTEM RELOAD USERS` 명령 자체까지 같이 거부**되는 것도 확인했습니다:
```
Code: 201. DB::Exception: Quota for user `default` for 60s has been exceeded: queries = 3/2.
```
운영 관점 교훈: SQL 기반 쿼터를 XML 기반 사용자에게 새로 연결한 뒤에는 **반드시
`SYSTEM RELOAD USERS`로 재적재를 확인**해야 하고, 쿼터를 잘못 설정해 자기 자신이
막히는 경우를 대비해 별도의(쿼터 미적용) 관리자 계정을 확보해두는 게 안전합니다.

### 20-6. 핵심 정리

| 설정 | 통제 대상 | 실측 |
|---|---|---|
| `max_memory_usage` | 쿼리 1개의 메모리 | 한도 초과 시 즉시 `MEMORY_LIMIT_EXCEEDED` |
| `max_execution_time` | 쿼리 1개의 실행 시간 | 설정 시간에 정확히 `TIMEOUT_EXCEEDED` |
| `KILL QUERY` | 이미 실행 중인 쿼리 | 즉시 `QUERY_WAS_CANCELLED` |
| `max_concurrent_queries_for_user` | 사용자별 동시 실행 수 | 한도 초과분만 즉시 거부 |
| `QUOTA` | 사용자별 시간당 누적 사용량 | 정확히 작동하지만, XML 사용자엔 `SYSTEM RELOAD USERS` 필요 |

---

## 21. 인제스트 내압/백프레셔

삽입이 병합(merge) 속도보다 빨라지면 무슨 일이 생기는지 확인합니다. `parts_to_delay_insert`
(지연 시작 임계값)와 `parts_to_throw_insert`(거부 임계값)를 낮게 잡은 테이블로 재현합니다.

```sql
CREATE TABLE backpressure_test (id UInt64, val String) ENGINE = MergeTree ORDER BY id
SETTINGS parts_to_delay_insert = 5, parts_to_throw_insert = 10, max_delay_to_insert = 3
```

단건 INSERT를 연속 실행하며 파트 수와 소요 시간을 관찰했더니, 평소엔 배경 병합이
파트를 빠르게 합쳐서 5개 문턱을 거의 안 넘었습니다. **병합을 완전히 멈추고**
(`SYSTEM STOP MERGES backpressure_test`) 다시 삽입하자 교과서적인 패턴이 그대로
나타났습니다:

| 삽입 순번 | 활성 파트 수 | 소요 시간 |
|---|---|---|
| 51~54 | 2~5 | ~0.13~0.33초 (정상) |
| 55 | 6 | 0.73초 |
| 56 | 7 | 1.33초 |
| 57 | 8 | 1.93초 |
| 58 | 9 | 2.53초 |
| 59 | 10 | 3.13초 (거의 `max_delay_to_insert=3` 상한에 도달) |
| 60 | 10 | **즉시 실패** — `Code: 252 (TOO_MANY_PARTS)` |

`parts_to_delay_insert`(5)를 넘어서자 파트 수에 **선형 비례**해 삽입이 점점 느려지다가
(0.73→1.33→1.93→2.53→3.13초), `parts_to_throw_insert`(10)에 도달하자 그제야 완전히
거부됩니다. 이 지연 메커니즘은 "삽입 속도를 병합 속도에 맞춰 스스로 늦추는" 자동
브레이크입니다 — 정상적인 워크로드에서는 병합이 이 지연 동안 따라잡아 거의 throw까지
가지 않는다는 것도 이번 실험(병합을 멈추기 전까지는 throw가 재현되지 않았던 것)에서
확인했습니다.

**운영 함의**: `TOO_MANY_PARTS` 에러를 실제로 본다면, 이미 그 전에 삽입 지연이 점점
길어지는 신호가 먼저 나타났을 것입니다(`system.query_log`의 INSERT 소요 시간 추세로
조기 감지 가능). 근본 원인은 대개 "삽입 배치가 너무 작음"(매 INSERT가 새 파트 하나를
만듦)이므로, `async_insert`나 애플리케이션 레벨 배치로 삽입 빈도를 줄이는 게 표준
해법입니다.

---

## 22. 무중단 스키마 변경

부하가 걸린 상태에서 `ALTER TABLE ADD/MODIFY COLUMN`이 정말로 블로킹 없이 끝나는지,
그리고 `ON CLUSTER` 환경에서 놓치기 쉬운 부분을 확인합니다.

### 22-1. `ADD COLUMN` — 부하 중에도 완전히 무중단

0.15초 간격으로 계속 INSERT하는 백그라운드 루프를 돌리며:

```sql
ALTER TABLE schema_migration_test_local ON CLUSTER 'cluster1'
ADD COLUMN extra_field String DEFAULT 'none'
```

12개 노드 전체에 0.36초 만에 완료됐고, 동시에 돌던 INSERT 루프에서 **에러 0건**,
소요 시간 튐도 없었습니다(최대 0.22초, 평소와 동일). 상수 기본값의 `ADD COLUMN`은
메타데이터만 바꾸는 작업이라 완전히 무중단이라는 걸 부하 상태에서 직접 확인했습니다.

### 22-2. `MODIFY COLUMN` (타입 변경)도 마찬가지로 무중단이지만…

```sql
ALTER TABLE schema_migration_test_local ON CLUSTER 'cluster1'
MODIFY COLUMN val LowCardinality(String)
```

이것도 0.57초 만에 끝났고 동시 INSERT 루프는 에러 0건이었습니다. 그런데 검증 쿼리를
**Distributed 테이블**로 돌리니 `toTypeName(val)`이 여전히 `String`이었습니다.

### 22-3. 핵심 함정: `Distributed` 테이블은 자기만의 스키마 스냅샷을 갖는다

로컬 테이블(`schema_migration_test_local`)에서 직접 확인하면 타입이 제대로
`LowCardinality(String)`로 바뀌어 있었습니다. 문제는 `Distributed` 테이블
(`schema_migration_test`)의 컬럼 정의가 **생성 시점에 찍힌 별도의 스냅샷**이라서,
로컬 테이블을 아무리 `ON CLUSTER`로 잘 바꿔도 Distributed 테이블 자체는 전혀 갱신되지
않는다는 것입니다. 실제로 새로 추가한 컬럼을 Distributed 테이블로 조회하면:

```sql
SELECT extra_field FROM schema_migration_test LIMIT 1
```
```
Code: 47. DB::Exception: Unknown expression identifier `extra_field`. (UNKNOWN_IDENTIFIER)
```

**조용히 무시되는 게 아니라 하드 에러입니다.** 로컬 테이블은 이미 완전히 마이그레이션
됐는데도, 그 컬럼을 참조하는 애플리케이션 쿼리는 Distributed 테이블을 통하는 한 전부
실패합니다. 해결은 Distributed 테이블에도 **동일한 ALTER를 별도로** 적용하는 것뿐입니다:

```sql
ALTER TABLE schema_migration_test ON CLUSTER 'cluster1'
ADD COLUMN extra_field String DEFAULT 'none',
MODIFY COLUMN val LowCardinality(String)
```

적용 후에는 Distributed 테이블 조회도 정상(`none`, `LowCardinality(String)`)으로
돌아옵니다.

### 22-4. 핵심 정리

| 항목 | 결과 |
|---|---|
| `ADD COLUMN` (상수 기본값), 부하 중 | 완전 무중단, 0.36초, 에러 0건 |
| `MODIFY COLUMN` (타입 변경), 부하 중 | 완전 무중단, 0.57초, 에러 0건 (로컬 테이블 기준) |
| `Distributed` 테이블 스키마 | **로컬 테이블 ALTER와 별개** — 반드시 Distributed 테이블에도 동일한 ALTER를 실행해야 함 |
| 누락 시 증상 | 조용한 무시가 아니라 `UNKNOWN_IDENTIFIER` 하드 에러 |

**운영 체크리스트에 추가할 것**: 스키마 마이그레이션 스크립트/도구를 만든다면
`_local ON CLUSTER`와 `Distributed 테이블 ON CLUSTER`에 **각각** ALTER를 내리는
단계를 명시적으로 두 번 넣어야 합니다 — 하나라도 빠지면 "로컬은 됐는데 앱은 계속
터지는" 상태로 배포가 끝나버립니다.

---

## 23. INSERT 멱등성/중복제거

`ReplicatedMergeTree`는 `insert_deduplicate`(기본값 1, 켜짐) 설정으로 **완전히 동일한
INSERT 블록**을 자동으로 걸러냅니다. 클라이언트가 타임아웃 후 같은 INSERT를 재시도하는
흔한 상황에서 중복이 생기지 않게 해주는 안전장치인데, 정확히 어떤 조건에서 얼마나
믿을 수 있는지 직접 검증했습니다. KAFKA-INTEGRATION.md의 "컨슈머 그룹을 바꾸면
재처리되어 중복이 생긴다"는 발견과도 직결되는 실험입니다.

### 23-1. 완전히 동일한 블록은 자동으로 걸러진다

```sql
CREATE TABLE dedup_test_local ON CLUSTER 'cluster1' (id UInt64, val String)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/dedup_test_local', '{replica}')
ORDER BY id
SETTINGS replicated_deduplication_window = 3;

INSERT INTO dedup_test_local VALUES (1,'a'),(2,'b'),(3,'c');
INSERT INTO dedup_test_local VALUES (1,'a'),(2,'b'),(3,'c');  -- 완전히 동일한 재시도
SELECT count() FROM dedup_test_local;  -- 6이 아니라 3
```

두 번째 INSERT는 조용히 무시되고 행 수는 3 그대로였습니다.

### 23-2. `replicated_deduplication_window`은 생각보다 훨씬 관대했다

`replicated_deduplication_window=3`으로 낮게 잡아뒀으니, 서로 다른 블록을 3~4개만
더 끼워 넣으면 원래 블록의 해시가 밀려나 재시도가 "새 데이터"로 다시 들어갈 거라
예상했습니다. 실제로는:

- 서로 다른 블록 4개(`100,101,102,103`)를 끼워 넣은 뒤 원래 블록을 재삽입 →
  **여전히 걸러짐**(`id=1`이 여전히 1건).
- 서로 다른 블록을 **20개 더**(총 24개 개입) 끼워 넣은 뒤 재시도해도 →
  **여전히 걸러짐**.
- Keeper의 `/clickhouse/tables/{shard}/dedup_test_local/deduplication_hashes`
  znode를 직접 조회하면 설정한 3개 근처의 항목만 보이는데도, 실제 중복 판정은
  훨씬 오래 유지됐습니다 — 정리(cleanup)가 설정값만큼 즉시/동기적으로 일어나지
  않고 지연되는 것으로 보입니다.

**실무적으로는 오히려 좋은 소식입니다**: `replicated_deduplication_window`을 작게
잡아도, 설정값이 암시하는 것보다 실제 보호 구간이 더 넓을 수 있습니다. 다만 이는
내부 정리 스케줄에 의존하는 동작이라 **보장된 값으로 설계에 반영하면 안 되고**,
정확한 중복 방지가 필요하다면 여전히 애플리케이션 레벨의 멱등 키(비즈니스
유니크 키 + `ReplacingMergeTree`)를 1차 방어선으로 둬야 합니다.

### 23-3. `insert_deduplicate=0`으로 끄면 바로 중복이 쌓인다 (대조군)

```sql
INSERT INTO dedup_test_local SETTINGS insert_deduplicate=0 VALUES (1,'a'),(2,'b'),(3,'c');
SELECT id, count() FROM dedup_test_local WHERE id=1 GROUP BY id;  -- 2
```

### 23-4. 핵심 함정: `Distributed` 테이블을 거치면 중복 방지가 깨진다

같은 실험을 로컬 테이블이 아니라 `Distributed` 테이블로 반복하면 결과가 다릅니다.

```sql
INSERT INTO dedup_test VALUES (500,'p'),(501,'q');
INSERT INTO dedup_test VALUES (500,'p'),(501,'q');  -- 완전히 동일한 재시도
SELECT id, count() FROM dedup_test WHERE id IN (500,501) GROUP BY id;  -- 둘 다 2
```

**로컬 테이블에 직접 넣을 때는 걸러지던 것과 정반대로, `Distributed` 테이블을 거치면
완전히 동일한 INSERT 문도 그대로 중복 삽입됩니다.** `Distributed` 엔진이 각 행을
샤딩 키(`rand()`)로 매 시도마다 새로 재계산해 샤드별로 쪼개기 때문에, "논리적으로
동일한" INSERT라도 실제 각 샤드가 받는 물리적 블록 내용이 시도마다 달라질 수 있어
블록 해시 기반 중복 판정이 작동하지 않는 것으로 보입니다.

이 발견은 KAFKA-INTEGRATION.md에서 "컨슈머 그룹 변경 → 재처리 → 중복"을 관찰했던
이유도 명확히 설명합니다 — 그 실험의 `kafka_demo.events`는 **일반 `MergeTree`**였고
(`ReplicatedMergeTree`가 아님), `insert_deduplicate`가 의미를 갖는 건 Replicated
계열뿐입니다(비복제 테이블은 `non_replicated_deduplication_window`가 **기본값 0 =
비활성**). 즉 그 실험에서 중복이 발생한 건 단순히 "일반 MergeTree는 애초에 이
보호 장치가 꺼져 있었다"는 것으로 정확히 설명됩니다.

### 23-5. 핵심 정리

| 경로 | 완전히 동일한 재시도 결과 |
|---|---|
| `ReplicatedMergeTree` 로컬 테이블 직접 INSERT | 자동으로 걸러짐(기본값) |
| `insert_deduplicate=0` | 걸러지지 않고 중복 쌓임 |
| `Distributed` 테이블 경유 INSERT | **걸러지지 않음** — 샤딩 키 재계산으로 블록이 매번 달라짐 |
| 일반(비복제) `MergeTree` | 기본적으로 중복 방지 자체가 꺼져 있음 |

**운영 함의**: INSERT 재시도 로직을 가진 애플리케이션/파이프라인(HTTP 클라이언트
타임아웃 재시도, Kafka 컨슈머 재처리 등)이 있다면, (1) 대상 테이블이 실제로
`ReplicatedMergeTree` 계열인지, (2) **`Distributed` 테이블을 거치지 않고 직접
로컬 샤드에 쓰는 경로인지**를 먼저 확인하세요. 둘 중 하나라도 아니면 블록 단위
중복 방지는 작동하지 않으므로, 자연 키 + `ReplacingMergeTree`(또는 애플리케이션
레벨 dedup)가 필수입니다.

---

## 24. Projection으로 쿼리 가속

`ALTER TABLE ... ADD PROJECTION`은 원본 테이블과 다른 정렬/집계 순서를 자동으로
유지해주는 내장 인덱스입니다. `ORDER BY id`인 테이블에서 `id`가 아닌 다른 컬럼으로
자주 필터링한다면 얼마나 도움이 되는지, 그리고 `Distributed` 테이블과의 관계(22절의
`ADD COLUMN` 함정과 같은 문제가 있는지)를 확인했습니다.

### 24-1. Projection 없이: 필터 컬럼이 정렬 키가 아니면 풀스캔

```sql
CREATE TABLE proj_test_local ON CLUSTER 'cluster1'
(id UInt64, category LowCardinality(String), region LowCardinality(String), amount Float64)
ENGINE = ReplicatedMergeTree(...) ORDER BY id;
-- 500만 행 적재 (region은 4개 값 균등 분포)

EXPLAIN indexes=1 SELECT region, sum(amount), count() FROM proj_test_local WHERE region='kr' GROUP BY region
```
```
ReadFromMergeTree (default.proj_test_local)
  Parts: 5 | Granules: 153
  Indexes: PrimaryKey Condition: true, Parts: 5/5, Granules: 153/153   -- 전혀 걸러지지 않음(풀스캔)
```

### 24-2. Projection 추가 + 백필

```sql
ALTER TABLE proj_test_local ON CLUSTER 'cluster1' ADD PROJECTION region_agg (
    SELECT region, sum(amount), count() GROUP BY region
);
-- 기존에 이미 쌓여있던 데이터에도 적용되도록 백필(신규 INSERT는 자동 유지되지만
-- 과거 데이터는 명시적으로 MATERIALIZE해야 함)
ALTER TABLE proj_test_local ON CLUSTER 'cluster1' MATERIALIZE PROJECTION region_agg;
```

### 24-3. 결과: 동일 쿼리가 자동으로 프로젝션을 골라 씀

```
Filter
  Filter column: region = 'kr'
  ReadFromMergeTree (region_agg)          -- 원본이 아니라 프로젝션에서 읽음
    Parts: 5 | Granules: 5                -- 153 -> 5, 약 30배 감소
    Indexes: PrimaryKey Keys: region, Condition: (region in ['kr','kr'])
```
결과값(`18334.46..., 312302`)은 프로젝션 적용 전후로 **정확히 동일** — 속도만
빨라졌을 뿐 정확성은 그대로입니다. 쿼리를 바꾸지 않아도 옵티마이저가 자동으로
더 저렴한 프로젝션을 선택했습니다.

### 24-4. `Distributed` 테이블과의 관계: `ADD COLUMN`과 다르다

22절에서는 `_local` 테이블에 `ADD COLUMN`을 해도 `Distributed` 테이블은 별도로
ALTER하지 않으면 그 컬럼을 아예 모른다는(하드 에러) 함정을 발견했습니다. Projection은
**정반대**입니다 — Projection은 컬럼처럼 "보이는 스키마"가 아니라 각 로컬 테이블
내부의 저장 방식/인덱스일 뿐이라, `_local ON CLUSTER`에만 추가하면 `Distributed`
테이블 쪽은 아무 조치 없이도 그 로컬 테이블로 라우팅될 때 자동으로 프로젝션을 씁니다.
`Distributed` 테이블로 같은 쿼리를 실행해 각 샤드가 프로젝션 기반으로 빠르게 답하고
합산되는 것을 확인했습니다(추가 ALTER 불필요).

### 24-5. 핵심 정리

| 항목 | 결과 |
|---|---|
| Projection 없이 비정렬 컬럼 필터 | 전체 파트/그래뉼 스캔 (153/153) |
| Projection 추가 + `MATERIALIZE` 후 | 옵티마이저가 자동 선택, 30배 적은 그래뉼 스캔, 결과는 동일 |
| 기존 데이터 반영 | 자동 안 됨 — `MATERIALIZE PROJECTION`으로 명시적 백필 필요 |
| `Distributed` 테이블과의 관계 | `ADD COLUMN`과 달리 **별도 조치 불필요** — 로컬 테이블 변경만으로 투명하게 적용됨 |

**주의**: Projection은 원본 데이터를 한 번 더(다른 정렬로) 저장하므로 **디스크
사용량이 늘어납니다**(집계 프로젝션은 원본보다 훨씬 작을 수 있지만, 원본 컬럼을
그대로 재정렬하는 프로젝션은 테이블 크기를 사실상 2배로 만들 수 있음) — 추가하기
전에 `system.projection_parts`로 실제 증가량을 확인하세요.

---

## 25. 메모리 스필오버(External Aggregation/Sort/JOIN) 검증

대용량 GROUP BY/ORDER BY/JOIN 쿼리가 메모리를 다 채우려 할 때, **파드가 OS OOM
killer에 죽는 것(전체 서버 다운)**과 **쿼리 하나만 정상적으로 실패하거나 디스크로
스필해서 계속 진행하는 것** 사이의 차이를 실측했습니다.

> **왜 진짜 OOM을 재현하지 않았는가**: 이 클러스터의 ClickHouse 파드는
> `resources: {}` — **메모리 상한이 전혀 설정돼 있지 않습니다.** 게다가 공유
> Colima VM 여유가 2GB 안팎으로 빠듯합니다(CHDB-BENCHMARK.md에서 겪은 사고
> 참고). 이 상태로 진짜 무제한 메모리 폭주를 유도하면 파드 하나가 아니라 VM
> 전체가 위험해집니다. 그래서 `max_memory_usage`를 항상 안전판으로 고정해두고,
> "스필 비활성 시 vs 활성 시"를 **같은 캡 안에서** 대조하는 방식으로 검증했습니다
> — 이 대조 자체가 스필 메커니즘이 실제로 메모리 사용량을 낮춰준다는 증거입니다.

### 25-1. GROUP BY (`max_bytes_before_external_group_by`)

800만 개의 서로 다른 그룹을 만드는 쿼리를 동일한 `max_memory_usage=300MB` 아래
스필 비활성/활성으로 대조했습니다.

```sql
-- 스필 비활성 (max_bytes_before_external_group_by=0) -> 실패
SELECT key, sum(val), count() FROM (
  SELECT number % 8000000 AS key, sin(number) AS val FROM numbers(40000000)
) GROUP BY key
SETTINGS max_memory_usage=300000000, max_bytes_before_external_group_by=0
-- Code: 241 MEMORY_LIMIT_EXCEEDED (약 286MiB에서 즉시 실패)
```
```sql
-- 스필 활성 (50MB 문턱) -> 같은 300MB 캡에서 성공
SETTINGS max_memory_usage=300000000, max_bytes_before_external_group_by=50000000
-- 2.68초, memory_usage=259.85MB(캡 이내), ExternalAggregationWritePart=68회,
-- 디스크에 483.65MB 스필
```

같은 쿼리, 같은 메모리 캡인데 스필 문턱만 낮췄더니 실패하던 쿼리가 정상
완료됐고, 실행 중 `/var/lib/clickhouse/tmp/`에 실제 스필 파일이 생겼다가
쿼리 종료 후 자동으로 정리되는 것도 확인했습니다.

**핵심 함정 — 스필은 "중간 상태"만 지켜주지 "최종 병합"까지 지켜주진 않습니다.**
그룹 수를 1,500만 개로 늘리자 **같은 스필 설정**에서도 다시 실패했는데, 이번엔
"병합(머지) 단계"에서 터졌습니다. `max_memory_usage`만 600MB로 올리자(스필 설정은
그대로) 성공했습니다 — 즉 external GROUP BY는 중간 누적 단계의 메모리는 디스크로
돌려 막아주지만, **스필된 조각들을 최종적으로 합치는 단계는 여전히 최종 결과의
distinct 그룹 수에 비례하는 메모리가 필요**합니다. 스필을 켰다고 해서
`max_memory_usage`를 결과 크기와 무관하게 낮춰도 된다는 뜻이 아닙니다.

### 25-2. JOIN (`join_algorithm='grace_hash'`)

우측(빌드 사이드) 500만 행짜리 JOIN을 동일하게 대조했습니다.

```sql
-- 기본 hash join -> 실패
... SETTINGS max_memory_usage=300000000, join_algorithm='hash'
-- Code: 241, "FillingRightJoinSide"에서 즉시 실패

-- grace_hash로 바꿔도... 여전히 실패!
... SETTINGS max_memory_usage=300000000, join_algorithm='grace_hash'
-- 여전히 Code: 241 (기본 설정으로는 hash join과 동일하게 동작)
```

**핵심 함정 — `join_algorithm='grace_hash'`만으로는 부족합니다.**
`grace_hash_join_initial_buckets`의 기본값이 **1**이라, 처음엔 일반 hash join과
똑같이 버킷 1개에 전부 몰아넣다가 뒤늦게 재분할을 시도합니다 — 그런데 그 반응이
`max_memory_usage`의 즉각적인 하드 체크보다 느려서, 결국 같은 지점에서 죽습니다.
**초기 버킷 수를 명시적으로 올려야** 처음부터 분할·스필이 일어납니다:

```sql
SETTINGS max_memory_usage=300000000, join_algorithm='grace_hash',
         grace_hash_join_initial_buckets=16
-- 0.72초 성공, memory_usage=165.60MB, ExternalJoinWritePart=32회, 95.48MB 스필
```

### 25-3. ORDER BY (`max_bytes_before_external_sort`) — 버전별 숨겨진 게이트

1억 행 정렬을 같은 방식으로 테스트했는데, `max_bytes_before_external_sort=50MB`를
설정했음에도 **계속 실패**했습니다(`max_memory_usage`를 1GB까지 올려도 동일) —
`system.query_log`의 `ExternalSortWritePart`가 **0**이어서 스필 자체가 전혀
발동하지 않고 있었습니다.

원인은 이 버전에 새로 추가된 설정 **`max_bytes_ratio_before_external_sort`
(기본값 0.5)**였습니다 — 설명에 명시된 대로 "`max_bytes_before_external_sort`는
여전히 존중되지만, 정렬 블록이 이 값보다 클 때만 스필한다"는 **추가 게이트**가
숨어있었습니다. 이 비율 게이트를 명시적으로 꺼야 절대값 설정이 실제로 동작합니다:

```sql
SETTINGS max_memory_usage=300000000, max_bytes_before_external_sort=50000000,
         max_bytes_ratio_before_external_sort=0
-- 13.04초 성공, memory_usage=217.05MB, ExternalSortWritePart=31회, 1.27GB 스필
```

**이건 이 랩에서 몇 번이고 반복된 패턴입니다** — 15절의 `enable_parallel_replicas`
(별도 설정 없이는 `max_parallel_replicas`가 무효), 바로 위 25-2절의 grace_hash
초기 버킷 수와 정확히 같은 모양: **"기능을 켜는 설정"과 "그 기능이 실제로 발동하는
조건"이 분리돼 있는 경우가 흔하고, 버전이 올라가며 새 게이트 설정이 조용히
추가되기도 합니다.**
운영 환경에 새로 배포하기 전에는 반드시 스테이징에서 `system.query_log`의
`ProfileEvents`(`External*WritePart`)로 **스필이 실제로 발동했는지 직접 확인**하세요 —
설정값만 믿고 "당연히 스필되겠지"라고 가정하면 안 됩니다.

### 25-4. 핵심 정리

| 쿼리 유형 | 활성화 설정 | 추가로 필요했던 것 | 실측 결과 |
|---|---|---|---|
| GROUP BY | `max_bytes_before_external_group_by` | (그대로 동작) | 스필 68회, 484MB, 2.68초 — 단 **최종 병합은 여전히 결과 크기만큼 메모리 필요** |
| JOIN | `join_algorithm='grace_hash'` | `grace_hash_join_initial_buckets`를 기본값(1)보다 높게 | 스필 32회, 95MB, 0.72초 |
| ORDER BY | `max_bytes_before_external_sort` | `max_bytes_ratio_before_external_sort=0` (신규 게이트 해제) | 스필 31회, 1.27GB, 13.04초 |

**운영 함의**: 이 세 메커니즘 모두 "설정 하나만 켜면 끝"이 아니라 **버전/알고리즘별
숨은 2차 조건**이 있습니다. `max_memory_usage`는 이 모든 실험에서 단 한 번도
뚫리지 않았습니다(항상 캡 이내에서 성공하거나, 캡을 넘기 직전 깔끔하게
`MEMORY_LIMIT_EXCEEDED`로 실패) — 즉 **리소스 제한이 없는 이 클러스터에서
`max_memory_usage`가 사실상 유일한 안전망**입니다. 이 설정 없이 스필 기능만
믿고 대용량 쿼리를 운영에 내보내면, 스필이 예상대로 발동하지 않는 버전/설정
조합을 만났을 때 파드 전체가 OOM killer에 죽는 시나리오를 막을 수단이 없습니다.

---

## 26. CHI `profiles`로 메모리/스필 설정을 클러스터 전체 기본값으로

25절의 모든 검증은 매 쿼리에 `SETTINGS`를 직접 붙여서 했습니다 — 실제 운영에서는
모든 애플리케이션/사용자가 매번 그걸 기억해서 붙여줄 거라 기대할 수 없습니다.
Altinity Operator의 CHI `spec.configuration.profiles`로 이 설정들을 **클러스터
전체의 기본 프로파일**로 걸어서, `SETTINGS` 없이 접속한 모든 클라이언트가
자동으로 보호받는지 확인했습니다.

### 26-1. 적용 전: 이 클러스터엔 원래 안전망이 전혀 없었다

프로파일을 걸기 전, 12개 파드 중 3개를 무작위로 뽑아 확인한 기본 상태:

```
max_memory_usage: 0        (무제한!)
max_bytes_before_external_group_by: 0   (비활성)
join_algorithm: direct,parallel_hash,hash,ie_join   (grace_hash 없음)
```

25절에서 이미 확인했듯 이 파드들엔 `resources.limits.memory`도 없습니다. 즉
**애플리케이션 하나가 SETTINGS 없이 무거운 쿼리를 날리면, ClickHouse 프로세스도
막지 않고 k8s도 막지 않는** 상태였습니다.

### 26-2. `manifests/chi.yaml`에 profiles 추가

```yaml
    profiles:
      default/max_memory_usage: "300000000"
      default/max_bytes_before_external_group_by: "50000000"
      default/max_bytes_before_external_sort: "50000000"
      default/max_bytes_ratio_before_external_sort: "0"
      default/join_algorithm: "grace_hash"
      default/grace_hash_join_initial_buckets: "16"
```

`spec.configuration.profiles`는 각 Pod의 `/etc/clickhouse-server/users.d/`로
마운트되는 `<profiles><default>...</default></profiles>` XML을 생성합니다
(`kubectl explain chi.spec.configuration.profiles`로 확인).

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/chi.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get chi chi -w   # Completed 대기
```

### 26-3. 핵심 발견: 파드 재시작 없이 반영된다

CHI 상태는 `Completed → InProgress → Completed`(약 130초)로 순환했지만,
**12개 파드 중 단 하나도 재시작되지 않았습니다**(`RESTARTS`/`AGE` 불변). 11절에서
"`config.d`에 새 파일을 추가하면 재시작이 필요하다"고 확인했던 것과 달리,
`users.d/`의 프로파일 변경은 ClickHouse가 **자체적으로 핫리로드**합니다 —
오퍼레이터가 순차적으로 ConfigMap을 갱신하는 동안(`InProgress`, 롤아웃 중간에
확인한 스냅샷에서 12개 중 1개만 새 값 반영, 나머지는 구 값), 각 파드는 그
변경을 감지해 프로세스 재시작 없이 새 설정을 반영했습니다.

### 26-4. 검증: `SETTINGS` 없이도 25절과 동일하게 동작하는가

25절에서 명시적 `SETTINGS`로 확인했던 세 가지를 이번엔 **아무 SETTINGS 없이**
그대로 재실행했습니다.

```sql
-- 800만 그룹 GROUP BY, SETTINGS 없음 -> 성공(스필 68회, 262MB)
-- 1500만 그룹 GROUP BY, SETTINGS 없음 -> 여전히 실패(같은 300MB 캡, 최종 병합 한계)
-- JOIN(우측 500만 행), SETTINGS 없음 -> 성공(grace_hash 스필 32회, 165MB)
-- ORDER BY(1억 행), SETTINGS 없음 -> 성공(정렬 스필 31회, 217MB)
```

`system.query_log`의 `ProfileEvents`로 확인한 스필 횟수·메모리 사용량이 25절의
명시적 `SETTINGS` 버전과 **거의 동일**했습니다 — 프로파일 기본값이 정확히 같은
보호를 제공한다는 뜻입니다. 1500만 그룹 쿼리는 25절과 마찬가지로 여전히
실패했는데(같은 300MB 캡 + "최종 병합은 결과 크기에 비례" 한계가 그대로 적용),
이는 프로파일 방식이 SETTINGS 방식을 완벽히 대체한다는 걸 보여주는 대조군입니다.

### 26-5. 오버라이드는 여전히 가능하다

```sql
SELECT key, sum(val), count() FROM (...) GROUP BY key
SETTINGS max_memory_usage=2000000000   -- 실패하던 1500만 그룹 쿼리가 이번엔 성공
```

프로파일 기본값(300MB)이 있어도, 특정 쿼리에서 명시적으로 더 큰 값을 주면
정상적으로 오버라이드됩니다 — ClickHouse의 설정 우선순위(쿼리 > 프로파일 > 서버
기본값)가 그대로 작동합니다. 즉 "평소엔 안전하게 막되, 필요할 때 관리자가 의도적으로
풀어줄 수 있다"는 두 마리 토끼를 다 잡습니다.

### 26-6. 핵심 정리

| 항목 | 결과 |
|---|---|
| 적용 전 이 클러스터 기본 상태 | `max_memory_usage=0`(무제한), 스필 전부 비활성 — 안전망 전혀 없음 |
| 반영 방식 | `spec.configuration.profiles` → `users.d/` → **파드 재시작 없이 핫리로드** |
| 롤아웃 소요 | 약 130초 (12개 파드 순차 반영, `InProgress` 중간 스냅샷으로 확인) |
| `SETTINGS` 없는 쿼리 동작 | 25절의 명시적 SETTINGS 버전과 거의 동일한 스필 횟수/메모리로 재현 |
| 오버라이드 | 쿼리 레벨 `SETTINGS`로 여전히 가능 (우선순위: 쿼리 > 프로파일) |

**운영 함의**: 25절의 발견들(스필 설정만 켜서는 부족한 숨은 게이트들)을 프로덕션에
반영하려면 각 애플리케이션 팀에게 SETTINGS를 붙이라고 요청하는 대신, **CHI
`profiles`로 클러스터 전체 기본값을 걸어두는 쪽이 훨씬 안전**합니다 — 클라이언트가
무엇을 알든 모르든 동일하게 보호되고, 배포도 파드 재시작 없이(`config.d` 변경보다
가벼움) 적용됩니다.

---

## 27. Query Queue & 동시성 제한 — 대기(Queue)와 HTTP 상태 코드

`max_concurrent_queries` 초과 시 정말로 "대기열"이 존재하는지, 그리고 서버
레벨(config.xml)과 사용자 프로필 레벨(users.xml) 설정을 어떻게 조합해야
하는지 확인했습니다.

### 27-1. 서버 레벨 vs 프로필 레벨 — 이름은 비슷해도 다른 설정

| 설정 | 위치 | 범위 |
|---|---|---|
| `max_concurrent_queries` | `system.server_settings`만 (config.xml 전용, 세션 설정 아님) | 서버 전체 |
| `max_concurrent_queries_for_all_users` | `system.settings` (프로필/세션) | 서버 전체(프로필 경유) |
| `max_concurrent_queries_for_user` | `system.settings` (프로필/세션) | 사용자별 |

적용 전 기본값은 `max_concurrent_queries=1000`(사실상 무제한), 나머지 둘은
`0`(무제한)이었습니다.

### 27-2. 핵심 발견: `queue_max_wait_ms`는 서버 레벨 한도에만 적용된다

`queue_max_wait_ms`(초과 시 대기할 시간, 기본 0=즉시 실패)를
`max_concurrent_queries_for_all_users`/`max_concurrent_queries_for_user`와
함께 걸어봤더니 **전혀 대기하지 않고 즉시 거부**됐습니다(0.14~0.15초).
프로필 레벨의 두 한도는 `queue_max_wait_ms`를 아예 무시합니다.

**`spec.configuration.settings`로 서버 레벨 `max_concurrent_queries`를
직접 설정**해야 대기가 실제로 동작합니다:

```yaml
# manifests/chi.yaml
    settings:
      max_concurrent_queries: "8"
```

> **파드 재시작 없이 반영됐습니다** — `chop-generated-settings.xml`은
> 11절에서 "새 파일 추가는 재시작 필요"라고 확인했던 것과 달리 이미 존재하던
> 파일의 **내용만 수정**하는 경우라, 프로파일 변경(26절)과 마찬가지로
> 핫리로드됐습니다(롤아웃 약 130초, 12개 파드 `RESTARTS`/`AGE` 불변).

배경에 8개의 슬롯을 채운 뒤 9번째 쿼리로 세 가지 경우를 실측했습니다:

| 케이스 | 배경 쿼리 소요 | `queue_max_wait_ms` | 9번째 쿼리 결과 |
|---|---|---|---|
| A. 기본값 | `sleep(3)` × 8 | `0` | **즉시**(0.16초) 거부 |
| B. 대기 후 성공 | `sleep(3)` × 8 | `5000`(대기 시간 > 필요 시간) | **2.05초 대기 후 성공** — 슬롯이 열리자마자 진행 |
| C. 대기 후 실패 | `sleep(3)` × 8 | `1000`(대기 시간 < 필요 시간) | **1.16초 대기 후** 거부(같은 `TOO_MANY_SIMULTANEOUS_QUERIES`) |

케이스 B/C는 에러 메시지 자체는 동일하지만, **실패까지 걸린 시간이 다르다는
것 자체가 "진짜로 대기했다"는 증거**입니다 — 즉시 거부(0.1초대)와 타임아웃
후 거부(설정한 `queue_max_wait_ms`만큼 경과 후)를 로그의 소요 시간만으로도
구분할 수 있습니다.

### 27-3. HTTP 인터페이스: 429도 503도 아니라 **500**

REST 관례상 "너무 많은 요청"은 429(Too Many Requests)나 503(Service
Unavailable)을 기대하기 쉽지만, 실측 결과는 달랐습니다.

```
$ wget -S -O- 'http://localhost:8123/?query=SELECT 999 SETTINGS queue_max_wait_ms=0'
HTTP/1.1 500 Internal Server Error
X-ClickHouse-Exception-Code: 202
```

**HTTP 상태 코드는 그냥 500입니다.** 실제 원인(동시 쿼리 한도 초과, 내부 코드
202/`TOO_MANY_SIMULTANEOUS_QUERIES`)은 `X-ClickHouse-Exception-Code` 헤더에만
담겨 있습니다. HTTP 인터페이스로 ClickHouse를 호출하는 애플리케이션이 "429/503만
재시도, 5xx는 알람"처럼 표준 REST 관례로 재시도 로직을 짰다면, **이 경우를
놓칠 수 있습니다** — 재시도 판단은 HTTP 상태 코드가 아니라
`X-ClickHouse-Exception-Code` 헤더(202면 재시도 가능, 다른 5xx 원인이면
알람)로 해야 합니다.

### 27-4. 서버 + 프로필 조합 가이드

실전에서 권장하는 3단 구성:

1. **서버 레벨(`configuration.settings`) `max_concurrent_queries`**: 이
   서버가 절대 넘지 않을 하드 캡(전체 코어/메모리 기준 산정). `queue_max_wait_ms`도
   여기서만 의미가 있으므로, 순간적인 버스트를 짧게 흡수하고 싶다면 이 레벨에서
   프로필로 `queue_max_wait_ms`를 함께 설정(수 초 단위 권장 — 너무 길면 클라이언트
   타임아웃과 충돌).
2. **프로필 레벨(`configuration.profiles`) `max_concurrent_queries_for_user`**:
   개별 애플리케이션/서비스 계정이 서버 전체 슬롯을 독점하지 못하게 하는
   테넌트 간 공정성 장치. 서버 캡보다 항상 작게.
3. **프로필 레벨 `max_concurrent_queries_for_all_users`**: 여러 사용자를 묶어
   "일반 사용자 그룹 전체"에 서버 캡보다 낮은 한도를 걸고, 운영자 전용 계정은
   이 한도에서 제외해 장애 상황에서도 조사용 쿼리를 실행할 수 있게 함
   (설정 설명에 명시된 공식 사용 사례).

```yaml
    settings:
      max_concurrent_queries: "8"            # 서버 전체 하드 캡
    profiles:
      default/max_concurrent_queries_for_all_users: "6"   # 일반 사용자 그룹
      default/queue_max_wait_ms: "3000"                    # 프로필에 걸어도 무방(단, 27-2절처럼 서버 레벨 캡에만 실제 적용됨)
      admin/max_concurrent_queries_for_all_users: "0"      # 운영자는 무제한(투자 조사용)
```

> 26절과 마찬가지로, `queue_max_wait_ms`를 프로필에 적어두는 것 자체는
> 문법 오류가 아니지만 **서버 레벨 한도에만 실제로 작동**한다는 27-2절의
> 발견을 반드시 감안하세요 — 프로필 레벨 한도만으로 "잠깐 기다렸다 재시도"를
> 기대하면 안 됩니다.

### 27-5. 핵심 정리

| 항목 | 결과 |
|---|---|
| 대기열(Queue) 존재 여부 | 있음 — 단 **서버 레벨 `max_concurrent_queries` + `queue_max_wait_ms`에서만** |
| 프로필 레벨 한도(`_for_user`, `_for_all_users`) | `queue_max_wait_ms` 무시, 항상 즉시 거부 |
| HTTP 상태 코드 | **500**(429/503 아님) — 실제 원인은 `X-ClickHouse-Exception-Code` 헤더로 판별 |
| 설정 반영 방식 | `config.d` 파일 내용 수정은 프로필과 마찬가지로 **파드 재시작 없이** 반영 |
| 권장 조합 | 서버 캡(하드 리밋+짧은 큐 대기) + 프로필 레벨 사용자/그룹별 한도(공정성) + 운영자 예외 |

---

## 28. 배치 vs 실시간 — 사용자 분리로 워크로드 격리하기

27절에서 "대기열은 서버 레벨 한도에만 적용된다"를 확인했으니, 사용자별로는
"대기"가 아니라 "즉시 거부 + 서로 다른 한도"로 배치/실시간을 분리하는 게
현실적인 방법입니다. 실제로 `batch_user`/`realtime_user` 두 사용자를 만들어
검증했습니다. 참고로 이 버전(26.9)엔 더 정교한 **CPU Workload Scheduling**
(`CREATE RESOURCE`/`CREATE WORKLOAD`) 기능도 있어서 함께 시도했습니다. 처음엔
우선순위 효과를 재현하지 못했지만, 재실험(28-3-1)에서 **루트 워크로드의 슬롯 상한이
없으면(또는 너무 크면) 우선순위가 아예 작동할 기회가 없다**는 원인을 찾아 검증했습니다.

### 28-1. 사용자 + 프로필 분리 (검증된 방법)

```yaml
# manifests/chi.yaml
    profiles:
      batch_profile/profile: "default"
      batch_profile/max_concurrent_queries_for_user: "2"
      batch_profile/max_execution_time: "300"
      realtime_profile/profile: "default"
      realtime_profile/max_concurrent_queries_for_user: "20"
      realtime_profile/max_execution_time: "5"
    users:
      batch_user/password: "batch_pass_2026"
      batch_user/profile: "batch_profile"
      batch_user/networks/ip: "::/0"
      realtime_user/password: "realtime_pass_2026"
      realtime_user/profile: "realtime_profile"
      realtime_user/networks/ip: "::/0"
```

**검증 1 — 동시성 격리**: `batch_user`로 슬롯 2개를 채운 뒤 3번째 쿼리를
날리면 정확히 `batch_user`만 거부되고, **그 순간 `realtime_user`는 완전히
정상 동작**했습니다.

```
batch_user 3번째: Code 202 "Too many simultaneous queries for user batch_user. Current: 2, maximum: 2."
realtime_user (동시): 'realtime-unaffected' 정상 반환
```

**검증 2 — 실행 시간 격리**: `realtime_user`(5초 제한)로 무거운 쿼리를 실행하면
정확히 5,000ms에서 `TIMEOUT_EXCEEDED`로 종료되지만, **같은 규모의 쿼리를
`batch_user`(300초 제한)로 실행하면 36.7초 만에 정상 완료**됩니다 — 배치는
오래 걸리는 걸 허용하고, 실시간은 빠르게 실패해서 앱이 대기하지 않게 합니다.

### 28-2. 겪은 함정: 프로필 상속 순서가 오버라이드를 무효화할 수 있다

`batch_profile`에 `max_memory_usage=2000000000`(2GB, 배치용으로 더 크게)을
명시하고 `profile: default`로 공통 설정(스필 옵션 등)도 상속받게 했는데,
실제 적용된 값은 2GB가 아니라 **`default`의 300MB 그대로**였습니다. 생성된
XML을 직접 열어보니:

```xml
<batch_profile>
    <max_concurrent_queries_for_user>2</max_concurrent_queries_for_user>
    <max_execution_time>300</max_execution_time>
    <max_memory_usage>2000000000</max_memory_usage>   <!-- 분명히 있음 -->
    <profile>default</profile>                          <!-- 그런데 이게 이 뒤에 옴 -->
</batch_profile>
```

Altinity Operator가 XML 자식 요소를 **알파벳 순으로 정렬**해서 생성하는데,
`max_memory_usage`(m)가 `profile`(p)보다 알파벳상 앞이라 `<profile>` 상속
태그가 **문서상 나중에** 옵니다. ClickHouse는 이 순서 그대로 처리해서, 나중에
나온 `<profile>default</profile>`이 그 앞의 명시적 `max_memory_usage`를
덮어써 버립니다. **자기 프로필에서 명시적으로 오버라이드하고 싶은 설정이
부모 프로필에도 있다면, 이 순서 문제 때문에 오버라이드가 조용히 무시될 수
있습니다** — 적용 후 반드시 `system.settings`로 실제 값을 재확인하세요
(이번처럼 `changed`/`value`를 사용자별로 직접 조회).

### 28-3. CPU Workload Scheduling(`CREATE WORKLOAD`)

이 버전엔 `system.workloads`/`system.resources`/`system.scheduler`로 조회 가능한
CPU 스케줄링 기능이 있습니다.

```sql
CREATE RESOURCE cpu (MASTER THREAD, WORKER THREAD);
CREATE WORKLOAD all_queries SETTINGS max_concurrent_threads = 100;
CREATE WORKLOAD batch IN all_queries SETTINGS max_concurrent_threads = 2 FOR cpu;
CREATE WORKLOAD realtime IN all_queries SETTINGS priority = -5 FOR cpu;
```

**확실히 검증된 것**: `FOR cpu`로 실제 자원에 연결해야 `system.scheduler`에
스케줄러 노드가 생기고 제약이 실제로 걸립니다(연결 안 하면 `max_concurrent_threads`
값은 저장만 되고 아무 효과가 없었습니다). **단독으로 실행한 쿼리**에서는
`workload='batch'`(2스레드 캡)가 `workload` 미지정(기본) 대비 명확히
느렸습니다(2.37초 vs 1.25초) — 워크로드별 CPU 예산 상한 자체는 실제로
작동합니다.

**첫 실험에서 검증하지 못한 것**: 위 설정으로 `batch`(낮은 우선순위, 스레드 캡)와
`realtime`(높은 우선순위)를 **동시에** 실행해 "실시간 쿼리가 더 빨리 끝나는지"
측정했을 때는 일관된 방향이 나오지 않았습니다(대조군 3.85s/5.05s, 분리 4.37s/4.32s).
원인은 아래 재실험에서 찾았습니다.

### 28-3-1. 재실험(2026-10-09): 우선순위는 "슬롯이 부족할 때만" 작동한다

**핵심 원리**: 워크로드 스케줄러는 CPU **슬롯**을 나눠주는 장치입니다. 루트
워크로드(`all_queries`)에 `max_concurrent_threads`가 없거나 첫 실험처럼 100으로
넉넉하면, 모든 스레드가 요청 즉시 슬롯을 받기 때문에 **우선순위가 끼어들 경쟁 자체가
없습니다**. 그러면 경쟁은 전부 OS 스케줄러(런큐)에서 일어나고, OS는 ClickHouse의
`priority`를 모릅니다.

**실험 설계** — 분산 쿼리 노이즈를 없애려고 파드 1개(`chi-chi-cluster1-0-0-0`)에서
로컬 CPU 쿼리만 사용했습니다(이 VM은 6코어를 19개 파드가 공유).

```bash
# 배치: 단독 ~36초짜리 쿼리 3개 동시 실행 (max_threads=6 × 3 = 18스레드)
SELECT sum(cityHash64(number)) FROM numbers_mt(100000000000) SETTINGS max_threads=6
# 실시간: 단독 ~1.1초짜리 쿼리. 배치 시작 3초 후 실행, 끝나면 배치 KILL
SELECT sum(cityHash64(number)) FROM numbers_mt(3000000000) SETTINGS max_threads=6
```

조건마다 `alone`(실시간 단독) / `nosched`(경합, 워크로드 미지정) / `sched`(경합,
`--workload=batch` vs `--workload=realtime`)를 **한 라운드 안에서 번갈아** 8라운드씩
실행하고, `system.query_log`의 `query_duration_ms`로 실시간 쿼리 시간을 집계했습니다.
루트 상한과 우선순위만 바꿔 가며 반복했습니다.

| 단계 | 루트 `max_concurrent_threads` | realtime `priority` | 실시간 p50 (min–max) | 대조군 nosched p50 | OS 런큐 대기 평균 |
|---|---|---|---|---|---|
| (단독) | — | — | **1.10s** (1.07–1.27) | — | ~30ms |
| U | 없음 | -5 | 2.52s (1.95–2.91) | 2.50s | 2.0s — **효과 없음** |
| B | 6 (=코어 수) | -5 | 2.12s (1.85–2.36) | 2.53s | 1.3s |
| C | 4 | -5 | 1.57s (1.38–1.89) | 2.45s | 0.42s |
| D | 4 | 0 (동일) | 1.48s (1.44–1.61) | 2.35s | 0.30s |
| F | 2 | 0 (동일) | 1.49s, 이봉분포(≈1.24 / ≈2.4) | 2.19s | 0.12s |
| **E** | **2** | **-5** | **1.12s (1.09–1.24, 이상치 1회 2.35)** | 2.40s | 0.05s |

**읽는 법**

1. **U — 상한 없음**: 첫 실험의 "효과 없음"이 그대로 재현됩니다. 슬롯 경쟁이
   없으니 우선순위는 무의미하고, 18+스레드가 6코어를 두고 OS 런큐에서 싸웁니다
   (`OSCPUWaitMicroseconds` ≈ 2초).
2. **C vs D — 상한 4에서 우선순위 유무가 같은 결과**: 개선(2.4s → 1.5s)은 전부
   **상한 덕분**(총 스레드를 코어 수 아래로 묶어 OS 런큐 대기가 2초 → 0.3초)이고,
   우선순위 기여는 측정되지 않았습니다. 실시간 쿼리는 슬롯을 2개만 원하는데
   (`ConcurrencyControlSlotsAcquired`=2), 동일 우선순위의 공정 분배(`fair` 노드)로도
   4개 중 절반인 2개를 받으므로 우선순위가 결정할 일이 없습니다.
3. **E vs F — 수요 > 공정 몫일 때 우선순위가 드러남**: 상한을 2로 낮추면 공정
   분배로는 실시간이 1개 슬롯만 받을 수 있습니다. 동일 우선순위(F)는 1.23s 근처와
   2.4s 근처로 **둘로 갈라지고**(슬롯 대기 평균 264ms), 우선순위 -5(E)는 8회 중
   7회가 **1.09–1.24s로 단독 실행(1.10s)과 사실상 같습니다**(슬롯 대기 평균 52ms).
   E의 2.35s 1회는 워크로드 변경 직후 첫 라운드에서 나왔고, 원인은 확정하지
   못했습니다.

참고로 우선순위가 서로 다르면 `system.scheduler`에 `priority` 노드가, 같으면 `fair`
노드(`p0_fair`)가 생깁니다 — 설정이 의도대로 반영됐는지 이 경로로 확인할 수 있습니다.

**대가 — 배치 처리량**: 종료된 배치 쿼리의 `read_rows / 실행시간`으로 보면 상한
4에서 약 -6~9%, 상한 2+우선순위(E)에서 **약 -33%**(1,506 → 1,001 M rows/s)였습니다.
실시간 지연을 단독 수준으로 지키는 대신 배치가 그만큼 느려집니다.

### 28-4. 핵심 정리

| 방법 | 검증 상태 | 결과 |
|---|---|---|
| 사용자별 프로필(`max_concurrent_queries_for_user`, `max_execution_time`) | ✅ 완전 검증 | 한 사용자가 한도를 채워도 다른 사용자는 완전히 무관하게 동작 |
| 프로필 상속(`profile: default`) + 같은 설정 오버라이드 | ⚠️ 함정 발견 | XML 알파벳 정렬 순서상 부모가 자식의 오버라이드를 덮어쓸 수 있음 — 반드시 재확인 |
| CPU Workload Scheduling — 스레드 상한 | ✅ 검증(단독 실행) | `FOR cpu` 연결 필수, 단독 쿼리에서 캡 확인(2.37s vs 1.25s) |
| CPU Workload Scheduling — 우선순위, 루트 상한 없음/넉넉함 | ❌ 무효 | 슬롯 경쟁이 없어 우선순위가 개입하지 않음(첫 실험의 원인) |
| CPU Workload Scheduling — 루트 상한 < 코어 수 | ✅ 검증(8회×조건) | OS 런큐 대기가 줄어 실시간 p50 2.4s → 1.5s (우선순위 없이도) |
| CPU Workload Scheduling — 상한 2 + 우선순위 -5 | ✅ 검증(8회) | 실시간 p50 1.12s ≈ 단독 1.10s, 배치 처리량 약 -33% |

**실전 권장**: 지금 당장 신뢰하고 쓸 수 있는 건 **사용자 + 프로필 분리**입니다
— 배치 계정은 낮은 동시성/긴 실행시간 허용, 실시간 계정은 높은 동시성/짧은
실행시간으로 빠르게 실패하게 설정하세요. CPU Workload Scheduling으로 "배치와
동시에 돌아도 실시간은 단독 실행만큼 빠르게"를 원한다면 두 가지가 모두 필요합니다: (1) 루트 워크로드에 **코어 수보다 작은**
`max_concurrent_threads`를 걸어 슬롯 경쟁을 만들고, (2) 실시간 워크로드에 더 낮은
`priority` 값을 주는 것. 상한이 없으면 우선순위는 아무 효과가 없고, 상한이 실시간
쿼리의 수요보다 넉넉하면 상한만으로 얻는 개선과 구분되지 않습니다. 상한을 낮출수록
배치 처리량을 그만큼 내준다는 점도 같이 고려하세요(이 랩에서는 상한 2일 때 -33%).

---

## 29. 정리

```bash
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/minio.yaml
kind delete cluster --name clickhouse-lab
```

(Colima 리소스를 원래대로 되돌리려면 `colima stop && colima start --cpu 4 --memory 8`)
