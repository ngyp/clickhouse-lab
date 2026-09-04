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

## 12. 클러스터 확장 & 리샤딩 (3→4 샤드)

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

## 13. 무중단 롤링 업그레이드

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

## 14. 부하 테스트 & `max_parallel_replicas` 실험

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

## 15. Mutation & TTL 라이프사이클

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

## 16. 네트워크 파티션 (스플릿 브레인) 시뮬레이션

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

## 17. 접속 (호스트에서 직접 붙어보기)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/clickhouse-chi 8123:8123 9000:9000
# 다른 터미널에서
clickhouse-client --host 127.0.0.1
# 또는
curl 'http://localhost:8123/?query=SELECT%201'
```

---

## 18. 정리

```bash
kind delete cluster --name clickhouse-lab
```

(Colima 리소스를 원래대로 되돌리려면 `colima stop && colima start --cpu 4 --memory 8`)
