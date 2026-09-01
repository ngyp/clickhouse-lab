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

## 12. 접속 (호스트에서 직접 붙어보기)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/clickhouse-chi 8123:8123 9000:9000
# 다른 터미널에서
clickhouse-client --host 127.0.0.1
# 또는
curl 'http://localhost:8123/?query=SELECT%201'
```

---

## 13. 정리

```bash
kind delete cluster --name clickhouse-lab
```

(Colima 리소스를 원래대로 되돌리려면 `colima stop && colima start --cpu 4 --memory 8`)
