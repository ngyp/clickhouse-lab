# ClickHouse 클러스터 실험 가이드 (kind + Free Operator + Keeper)

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

## 3. Altinity Operator 없이 직접 구성

Altinity ClickHouse Operator를 사용하지 않고 Kubernetes 기본 리소스를 직접 정의하여 ClickHouse 환경을 구성합니다.

Operator를 사용하지 않으므로 `ClickHouseKeeperInstallation(CHK)`, `ClickHouseInstallation(CHI)`과 같은 Custom Resource는 사용하지 않습니다.

이후 단계에서는 `StatefulSet`, `Service`, `ConfigMap` 등의 Kubernetes 리소스를 직접 생성하여 다음과 같이 구성합니다.

```
3. Namespace 구성
 │
 └─ clickhouse-lab namespace 생성/확인

4. ClickHouse Keeper 구성
 │
 ├─ 4-1. Keeper ConfigMap
 ├─ 4-2. Keeper Headless Service
 └─ 4-3. Keeper StatefulSet
        ↓
     Keeper 3대 Running
     keeper-0 / keeper-1 / keeper-2

5. ClickHouse Server 구성
 │
 ├─ 5-1. ClickHouse ConfigMap
 ├─ 5-2. ClickHouse Headless Service
 ├─ 5-3. ClickHouse StatefulSet
 └─ 5-4. Cluster / Replication 확인
        ↓
     ClickHouse 3대 Running
     clickhouse-0 / clickhouse-1 / clickhouse-2
```

먼저 ClickHouse 리소스를 배포할 namespace를 생성합니다.

```bash
kubectl --context kind-clickhouse-lab create namespace clickhouse
kubectl --context kind-clickhouse-lab get namespace clickhouse #namespace가 생성되었는지 확인
```
---

## 4. ClickHouse Keeper 구성 - Free Operator(StatefulSet, 3노드)

Operator를 사용하지 않고 동일한 구성을 Kubernetes 기본 리소스로 직접 구성합니다.
Keeper는 다음과 같이 3개의 Pod로 구성합니다.

```text
clickhouse-keeper-0
clickhouse-keeper-1
clickhouse-keeper-2
```

이를 위해 다음 Kubernetes 리소스를 직접 생성합니다.

- `ConfigMap`: ClickHouse Keeper 설정
- `Headless Service`: Keeper Pod 간 DNS 통신
- `StatefulSet`: Keeper 3개 Pod 실행

사용할 manifest는 다음과 같습니다.

```text
manifests/
├── keeper-config.yaml
├── keeper-service.yaml
└── keeper-statefulset.yaml
```

### 4-1. Keeper Headless Service 생성

먼저 Keeper Pod들이 고정된 DNS 이름으로 서로 통신할 수 있도록 Headless Service를 생성합니다.

`manifests/keeper-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: clickhouse-keeper
  namespace: clickhouse
spec:
  clusterIP: None
  selector:
    app: clickhouse-keeper
  ports:
    - name: client
      port: 2181
      targetPort: 2181
    - name: raft
      port: 9444
      targetPort: 9444
```

Service를 생성합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/keeper-service.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get service clickhouse-keeper #생성 여부를 확인
```
`CLUSTER-IP`가 `None`으로 표시되면 Headless Service가 정상적으로 생성된 것입니다.

### 4-2. Keeper ConfigMap 생성

Keeper가 3개의 노드로 구성되어 Raft 기반으로 동작할 수 있도록 설정 파일을 생성합니다.

각 Keeper는 고유한 `server_id`를 가져야 하며, 서로 통신할 수 있도록 `raft_configuration`을 설정합니다.

`manifests/keeper-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-keeper-config
  namespace: clickhouse
data:
  keeper_config.yaml: |
    logger:
      level: information
      console: true

    keeper_server:
      tcp_port: 2181
      server_id: ${KEEPER_SERVER_ID}

      log_storage_path: /var/lib/clickhouse/coordination/log
      snapshot_storage_path: /var/lib/clickhouse/coordination/snapshots

      coordination_settings:
        operation_timeout_ms: 10000
        session_timeout_ms: 30000
        raft_logs_level: information

      raft_configuration:
        server:
          - id: 1
            hostname: clickhouse-keeper-0.clickhouse-keeper
            port: 9444

          - id: 2
            hostname: clickhouse-keeper-1.clickhouse-keeper
            port: 9444

          - id: 3
            hostname: clickhouse-keeper-2.clickhouse-keeper
            port: 9444
```

ConfigMap을 생성합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/keeper-config.yaml
kubectl --context kind-clickhouse-lab  -n clickhouse get configmap clickhouse-keeper-config #생성 여부를 확인
kubectl --context kind-clickhouse-lab -n clickhouse get configmap clickhouse-keeper-config -o yaml #설정내용 확인
```

### 4-3. Keeper StatefulSet 생성

이제 ClickHouse Keeper를 실제로 실행할 `StatefulSet`을 생성합니다.

```text
clickhouse-keeper-0
clickhouse-keeper-1
clickhouse-keeper-2
```

각 Pod는 고유한 `server_id`를 가져야 하므로 Pod 이름의 ordinal 값을 이용해 `1`, `2`, `3`을 생성합니다.

`manifests/keeper-statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse-keeper
  namespace: clickhouse
spec:
  serviceName: clickhouse-keeper
  replicas: 3

  selector:
    matchLabels:
      app: clickhouse-keeper

  template:
    metadata:
      labels:
        app: clickhouse-keeper

    spec:
      containers:
        - name: clickhouse-keeper
          image: clickhouse/clickhouse-keeper:latest

          command:
            - /bin/bash
            - -c
            - |
              ORDINAL="${HOSTNAME##*-}"
              SERVER_ID=$((ORDINAL + 1))

              echo "Pod: ${HOSTNAME}"
              echo "Keeper server_id: ${SERVER_ID}"

              sed "s/\${KEEPER_SERVER_ID}/${SERVER_ID}/g" \
                /etc/clickhouse-keeper-config/keeper_config.yaml \
                > /etc/clickhouse-keeper/keeper_config.yaml

              exec clickhouse-keeper \
                --config-file=/etc/clickhouse-keeper/keeper_config.yaml

          ports:
            - name: client
              containerPort: 2181

            - name: raft
              containerPort: 9444

          volumeMounts:
            - name: keeper-config
              mountPath: /etc/clickhouse-keeper-config

            - name: keeper-config-runtime
              mountPath: /etc/clickhouse-keeper

            - name: keeper-data
              mountPath: /var/lib/clickhouse

      volumes:
        - name: keeper-config
          configMap:
            name: clickhouse-keeper-config

        - name: keeper-config-runtime
          emptyDir: {}

  volumeClaimTemplates:
    - metadata:
        name: keeper-data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```

StatefulSet을 생성합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/keeper-statefulset.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get pods # pod 상태 확인
```
정상적으로 생성되면 다음과 같이 3개의 Keeper Pod가 표시됩니다.

```text
clickhouse-keeper-0
clickhouse-keeper-1
clickhouse-keeper-2
```

```bash
kubectl --context kind-clickhouse-lab -n clickhouse get statefulset clickhouse-keeper #StatefulSet 상태도 확인
kubectl --context kind-clickhouse-lab -n clickhouse logs clickhouse-keeper-0 #Keeper 로그를 확인
kubectl --context kind-clickhouse-lab -n clickhouse get pvc #PVC 생성 여부를 확인
```

---

## 5. ClickHouse 클러스터 직접 배포 (3샤드 × 3레플리카 + PVC)

Altinity Operator를 사용하지 않고 Kubernetes 기본 리소스인 `ConfigMap`, `Service`, `StatefulSet`을 이용하여 ClickHouse 클러스터를 직접 구성한다.

구성은 다음과 같다.

```text
ClickHouse Keeper
├── clickhouse-keeper-0
├── clickhouse-keeper-1
└── clickhouse-keeper-2

ClickHouse Cluster (cluster1)
├── Shard 1
│   ├── clickhouse-0 (replica 1)
│   ├── clickhouse-1 (replica 2)
│   └── clickhouse-2 (replica 3)
├── Shard 2
│   ├── clickhouse-3 (replica 1)
│   ├── clickhouse-4 (replica 2)
│   └── clickhouse-5 (replica 3)
└── Shard 3
    ├── clickhouse-6 (replica 1)
    ├── clickhouse-7 (replica 2)
    └── clickhouse-8 (replica 3)
```

각 ClickHouse Pod는 PVC를 하나씩 사용한다.

### 5-1. ClickHouse 공통 설정 생성

`manifests/clickhouse-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-config
  namespace: clickhouse
data:
  cluster.yaml: |
    remote_servers:
      cluster1:
        shard:
          - internal_replication: true
            replica:
              - host: clickhouse-0.clickhouse-headless
                port: 9000
              - host: clickhouse-1.clickhouse-headless
                port: 9000
              - host: clickhouse-2.clickhouse-headless
                port: 9000

          - internal_replication: true
            replica:
              - host: clickhouse-3.clickhouse-headless
                port: 9000
              - host: clickhouse-4.clickhouse-headless
                port: 9000
              - host: clickhouse-5.clickhouse-headless
                port: 9000

          - internal_replication: true
            replica:
              - host: clickhouse-6.clickhouse-headless
                port: 9000
              - host: clickhouse-7.clickhouse-headless
                port: 9000
              - host: clickhouse-8.clickhouse-headless
                port: 9000

    zookeeper:
      node:
        - host: clickhouse-keeper-0.clickhouse-keeper
          port: 2181
        - host: clickhouse-keeper-1.clickhouse-keeper
          port: 2181
        - host: clickhouse-keeper-2.clickhouse-keeper
          port: 2181

  server.yaml: |
    listen_host: "0.0.0.0"
    interserver_http_port: 9009
```

적용:

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-config.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get configmap clickhouse-config
```

### 5-2. ClickHouse Headless Service 생성

StatefulSet의 각 Pod가 고정된 DNS 이름으로 서로 통신할 수 있도록 Headless Service를 생성한다.

`manifests/clickhouse-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: clickhouse-headless
  namespace: clickhouse
spec:
  clusterIP: None
  publishNotReadyAddresses: true

  selector:
    app: clickhouse

  ports:
    - name: http
      port: 8123
      targetPort: 8123

    - name: native
      port: 9000
      targetPort: 9000

    - name: interserver
      port: 9009
      targetPort: 9009
```

적용:

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-service.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get svc clickhouse-headless
```
`CLUSTER-IP`가 `None`이면 정상이다.

StatefulSet에 의해 생성되는 Pod는 다음과 같은 DNS 이름을 갖게 된다.

```text
clickhouse-0.clickhouse-headless
clickhouse-1.clickhouse-headless
...
clickhouse-8.clickhouse-headless
```

### 5-3. ClickHouse StatefulSet 생성

하나의 StatefulSet으로 ClickHouse Pod 9개를 생성한다.

각 Pod의 ordinal을 기준으로 shard와 replica를 다음과 같이 구성한다.

```text
ordinal 0 → shard 01 / replica 01
ordinal 1 → shard 01 / replica 02
ordinal 2 → shard 01 / replica 03

ordinal 3 → shard 02 / replica 01
ordinal 4 → shard 02 / replica 02
ordinal 5 → shard 02 / replica 03

ordinal 6 → shard 03 / replica 01
ordinal 7 → shard 03 / replica 02
ordinal 8 → shard 03 / replica 03
```

`ReplicatedMergeTree`에서 사용할 `{shard}`, `{replica}` 매크로는 `initContainer`에서 각 Pod별로 생성한다.

`manifests/clickhouse-statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse
  namespace: clickhouse

spec:
  serviceName: clickhouse-headless
  replicas: 9

  selector:
    matchLabels:
      app: clickhouse

  template:
    metadata:
      labels:
        app: clickhouse

    spec:
      initContainers:
        - name: generate-macros
          image: busybox:1.36

          command:
            - sh
            - -c
            - |
              ORDINAL=${HOSTNAME##*-}

              SHARD=$((ORDINAL / 3 + 1))
              REPLICA=$((ORDINAL % 3 + 1))

              cat <<EOF > /generated-config/macros.yaml
              macros:
                shard: "$(printf '%02d' ${SHARD})"
                replica: "$(printf '%02d' ${REPLICA})"

              interserver_http_host: "${HOSTNAME}.clickhouse-headless.clickhouse.svc.cluster.local"
              EOF

              echo "Generated macros:"
              cat /generated-config/macros.yaml

          volumeMounts:
            - name: generated-config
              mountPath: /generated-config

      containers:
        - name: clickhouse
          image: clickhouse/clickhouse-server:latest

          ports:
            - name: http
              containerPort: 8123

            - name: native
              containerPort: 9000

            - name: interserver
              containerPort: 9009

          volumeMounts:
            - name: clickhouse-data
              mountPath: /var/lib/clickhouse

            - name: clickhouse-config
              mountPath: /etc/clickhouse-server/config.d/cluster.yaml
              subPath: cluster.yaml

            - name: clickhouse-config
              mountPath: /etc/clickhouse-server/config.d/server.yaml
              subPath: server.yaml

            - name: generated-config
              mountPath: /etc/clickhouse-server/config.d/macros.yaml
              subPath: macros.yaml

      volumes:
        - name: clickhouse-config
          configMap:
            name: clickhouse-config

        - name: generated-config
          emptyDir: {}

  volumeClaimTemplates:
    - metadata:
        name: clickhouse-data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 2Gi
```

적용:

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-statefulset.yaml
kubectl --context kind-clickhouse-lab -n clickhouse get pods -w
```

정상적으로 구성되면 9개의 ClickHouse Pod가 생성된다.

```text
clickhouse-0   1/1   Running
clickhouse-1   1/1   Running
clickhouse-2   1/1   Running
clickhouse-3   1/1   Running
clickhouse-4   1/1   Running
clickhouse-5   1/1   Running
clickhouse-6   1/1   Running
clickhouse-7   1/1   Running
clickhouse-8   1/1   Running
```

PVC 확인:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse get pvc
```
총 9개의 `clickhouse-data-*` PVC가 생성되었는지 확인한다.

### 5-4. shard / replica 설정 확인

각 Pod에 생성된 ClickHouse macro를 확인한다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- \
  cat /etc/clickhouse-server/config.d/macros.yaml
```

예상 결과:

```yaml
macros:
  shard: "01"
  replica: "01"

interserver_http_host: "clickhouse-0.clickhouse-headless.clickhouse.svc.cluster.local"
```

다른 Pod도 확인한다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-4 -- \
  cat /etc/clickhouse-server/config.d/macros.yaml
```

예상 결과:

```yaml
macros:
  shard: "02"
  replica: "02"

interserver_http_host: "clickhouse-4.clickhouse-headless.clickhouse.svc.cluster.local"
```

마지막 Pod도 확인한다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-8 -- \
  cat /etc/clickhouse-server/config.d/macros.yaml
```

예상 결과:

```yaml
macros:
  shard: "03"
  replica: "03"

interserver_http_host: "clickhouse-8.clickhouse-headless.clickhouse.svc.cluster.local"
```

---

### 5-5. ClickHouse 클러스터 상태 확인

첫 번째 ClickHouse Pod에서 `system.clusters`를 조회한다.

```bash
kubectl --context kind-clickhouse-lab \
  -n clickhouse exec clickhouse-0 -- \
  clickhouse-client -q "
    SELECT
        cluster,
        shard_num,
        replica_num,
        host_name
    FROM system.clusters
    WHERE cluster = 'cluster1'
    ORDER BY shard_num, replica_num
    FORMAT PrettyCompact
  "
```

총 9개의 host가 조회되어야 한다.

```text
cluster1    1    1    clickhouse-0.clickhouse-headless
cluster1    1    2    clickhouse-1.clickhouse-headless
cluster1    1    3    clickhouse-2.clickhouse-headless

cluster1    2    1    clickhouse-3.clickhouse-headless
cluster1    2    2    clickhouse-4.clickhouse-headless
cluster1    2    3    clickhouse-5.clickhouse-headless

cluster1    3    1    clickhouse-6.clickhouse-headless
cluster1    3    2    clickhouse-7.clickhouse-headless
cluster1    3    3    clickhouse-8.clickhouse-headless
```

Keeper 연결 여부도 확인한다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- \
  clickhouse-client -q "
    SELECT *
    FROM system.zookeeper
    WHERE path = '/'
  "
```

정상적으로 결과가 반환되면 ClickHouse Server에서 Keeper에 연결할 수 있는 상태이다.

이제 Operator를 사용하는 `operator 사용 할 때`와 동일하게 `3 shards × 3 replicas` 구조의 ClickHouse 클러스터가 준비되었다.

---

## 6. 클러스터 토폴로지 및 샤딩/복제 검증

### 6-1. 토폴로지 확인

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- \
  clickhouse-client -q "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num FORMAT PrettyCompact"
```

9개 host(3샤드×3레플리카)가 조회되어야 합니다(5-5절에서 이미 확인한 것과 동일).

### 6-2. ReplicatedMergeTree + Distributed 테이블 생성

이 구성에는 오퍼레이터가 자동으로 넣어주는 `default_replica_path`/`default_replica_name`이
없으므로, ZooKeeper 경로와 레플리카 이름을 `{shard}`/`{replica}` 매크로로 **직접** 지정해야
합니다(매크로는 5-3절의 `generate-macros` initContainer가 이미 각 Pod에 심어뒀습니다).

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
CREATE TABLE events_local ON CLUSTER 'cluster1'
(
    id UInt64,
    event_time DateTime,
    payload String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events_local', '{replica}')
ORDER BY id
"

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
CREATE TABLE events ON CLUSTER 'cluster1' AS events_local
ENGINE = Distributed('cluster1', currentDatabase(), events_local, rand())
"
```

`ON CLUSTER`는 Altinity Operator가 아니라 ClickHouse 서버 자체의 기능(Keeper를 통한
distributed DDL queue)이라, 오퍼레이터 없이 직접 구성한 이 클러스터에서도 그대로
동작합니다 — `zookeeper:` 블록(5-1절)이 연결돼 있기만 하면 됩니다.

### 6-3. 데이터 삽입 및 분산/복제 확인

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
INSERT INTO events SELECT number, now(), concat('payload-', toString(number)) FROM numbers(9000)
"

# Distributed 테이블 총합 (9000이어야 함)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM events"

# 샤드별 분산 (각 샤드의 대표로 replica 1: clickhouse-0/3/6)
for pod in clickhouse-0 clickhouse-3 clickhouse-6; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SELECT count() FROM events_local"
done

# 샤드1(clickhouse-0/1/2)의 3개 레플리카가 서로 동일한지 (복제 확인)
for pod in clickhouse-0 clickhouse-1 clickhouse-2; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SELECT count() FROM events_local"
done
```

---

## 7. 장애 복구 실험

> **이 구성과 Operator 구성의 근본적인 차이**: Altinity Operator는 레플리카마다
> **별도의 StatefulSet**을 만들어서(`chi-chi-cluster1-0-0`, `chi-chi-cluster1-0-1`, ...)
> 그중 하나만 골라 `replicas=0`으로 스케일할 수 있었습니다. 이 구성은 9개 Pod
> 전체를 **StatefulSet 하나**(`clickhouse`)가 관리하므로, `replicas`를 낮추면
> Kubernetes가 **항상 가장 높은 ordinal부터** 순서대로 제거합니다 — 중간의 특정
> 레플리카 하나만 콕 집어 "장기간" 내리는 건 `replicas` 스케일만으로는 불가능합니다.
> 이 차이가 아래 실험들에서 반복해서 등장합니다.

### 7-1. 파드만 삭제 (PVC 유지) → 완전 자동 복구

`kubectl delete pod`는 ordinal과 무관하게 특정 Pod 하나를 정확히 지울 수 있고,
StatefulSet 컨트롤러가 **즉시 같은 이름·같은 PVC로 재생성**합니다(`replicas` 값은
그대로라 "제거" 취급이 아님). 중간 레플리카(`clickhouse-4`, 샤드2/레플리카2)로
시연합니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse delete pod clickhouse-4

# 재기동 대기
kubectl --context kind-clickhouse-lab -n clickhouse get pod clickhouse-4 -w

# 데이터가 즉시 그대로 살아있는지 확인 (같은 PVC 재부착)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-4 -- clickhouse-client -q "SELECT count() FROM events_local"
kubectl --context kind-clickhouse-lab -n clickhouse get pvc clickhouse-data-clickhouse-4   # 볼륨 이름/나이 그대로인지 확인
```

**결과**: StatefulSet이 파드를 재생성하고, 같은 PVC(`clickhouse-data-clickhouse-4`)를
그대로 재부착하므로 재동기화 없이 즉시 정상입니다.

### 7-2. 파드 + PVC 삭제 (진짜 디스크 유실) → 수동 개입 필요

중간 ordinal(`clickhouse-4`)의 PVC만 콕 집어 지우려면, 위에서 설명한 이유로
`replicas`를 그 ordinal **아래로** 낮춰서 `clickhouse-4`부터 `clickhouse-8`까지
한꺼번에 내려야 합니다(다른 Operator 구성처럼 레플리카 하나만 건드릴 수는
없다는 이 구성의 한계입니다 — `clickhouse-5`~`8`의 PVC는 그대로 두므로 그
데이터는 잃지 않습니다).

```bash
# 1) ordinal 4 이상을 전부 내림 (4,5,6,7,8 다섯 개 Pod 제거, PVC는 유지됨)
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=4
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/clickhouse-8 --timeout=60s

# 2) clickhouse-4의 PVC만 삭제 (진짜 디스크 유실 시뮬레이션)
kubectl --context kind-clickhouse-lab -n clickhouse delete pvc clickhouse-data-clickhouse-4

# 3) 다시 9로 스케일 → clickhouse-4는 완전히 새로운 빈 PVC로, 5~8은 기존 PVC 그대로 재생성
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=9
kubectl --context kind-clickhouse-lab -n clickhouse get pod -w
```

**증상 확인**:

```bash
# 테이블이 사라짐 (SHOW TABLES 결과 없음)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-4 -- clickhouse-client -q "SHOW TABLES"

# 다른 노드에서 보면 이 레플리카가 비활성으로 인지됨 (active_replicas < total_replicas)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-3 -- clickhouse-client -q \
  "SELECT replica_name, active_replicas, total_replicas FROM system.replicas WHERE table='events_local'"

# 그래도 Distributed 쿼리는 나머지 2개 레플리카(clickhouse-3, clickhouse-5)로 자동 우회되어 계속 정상 응답
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q "SELECT count() FROM events"
```

**수동 복구 절차**:

```bash
# 1) Keeper에 남은 옛 레플리카 등록(좀비 상태) 정리
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-3 -- clickhouse-client -q \
  "SYSTEM DROP REPLICA '02' FROM ZKPATH '/clickhouse/tables/02/events_local'"

# 2) 빈 디스크에 테이블을 다시 붙임 (ON CLUSTER 아님, 이 노드에서만 실행)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-4 -- clickhouse-client -q "
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
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-4 -- clickhouse-client -q "SELECT count() FROM events_local"
```

> 매크로 `{replica}`는 ordinal 기준 `REPLICA=ORDINAL%3+1`로 계산되므로, `clickhouse-4`는
> `shard=02`, `replica=02`입니다(5-4절 참고). `SYSTEM DROP REPLICA`의 레플리카 이름
> 인자는 실제 매크로 값(`02`)을 그대로 씁니다.

### 7-3. 두 시나리오 요약

| 시나리오 | K8s 자동복구 | ClickHouse 자동복구 |
|---|---|---|
| 파드만 삭제 (PVC 유지) | O (`kubectl delete pod`로 즉시, ordinal 무관) | O (디스크 그대로라 즉시 정상) |
| 파드+PVC 삭제 (진짜 디스크 장애) | O (재스케줄, 빈 볼륨) — 단 이 구성은 **대상 ordinal 이상을 통째로 내렸다 올려야** 함 | X — 스키마/레플리카 재등록은 수동 |
| (재등록 이후) | - | O — 파트 재동기화는 완전 자동 |

Operator 구성은 레플리카마다 독립된 StatefulSet이라 "그 레플리카 하나만" 정밀하게
다룰 수 있었지만, 이 구성은 StatefulSet이 하나뿐이라 **중간 레플리카의 PVC만
삭제하려면 그보다 높은 ordinal도 함께 내려야 하는 대가**가 있습니다. 실제 운영에서
세밀한 레플리카별 제어가 필요하다면 이 점이 Operator를 쓰는 이유 중 하나입니다.

---

## 8. Distributed 테이블 로드밸런싱(`load_balancing`) 정책 실험

`load_balancing`은 Distributed 테이블이 **하나의 샤드 안에서 여러 레플리카 중 어느 것에
쿼리를 보낼지**를 결정하는 쿼리/세션 레벨 설정입니다 (`SETTINGS load_balancing='...'`).

### 8-1. 관찰용 트릭: `remote()` + `{a|b|c}` 문법

Headless Service(`clickhouse-headless`)가 만들어주는 Pod별 DNS 이름을 그대로
`remote()`에 씁니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
SELECT hostName() FROM remote('{clickhouse-0|clickhouse-1|clickhouse-2}.clickhouse-headless', system.one)
SETTINGS load_balancing='in_order'
"
```

### 8-2. 정책별 테스트

```bash
# in_order — 항상 목록의 첫 번째 레플리카만 선택
for i in $(seq 1 10); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{clickhouse-0|clickhouse-1|clickhouse-2}.clickhouse-headless', system.one) SETTINGS load_balancing='in_order'
  "
done

# random (기본값) — 균등 무작위 분산
for i in $(seq 1 15); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{clickhouse-0|clickhouse-1|clickhouse-2}.clickhouse-headless', system.one) SETTINGS load_balancing='random'
  "
done | sort | uniq -c

# nearest_hostname — 쿼리를 실행한 노드 자신과 이름이 같은 레플리카를 우선
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-2 -- clickhouse-client -q "
SELECT hostName() FROM remote('{clickhouse-0|clickhouse-1|clickhouse-2}.clickhouse-headless', system.one) SETTINGS load_balancing='nearest_hostname'
"

# first_or_random — 정상 상태에서는 in_order와 동일 (장애 시에만 무작위 폴백)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
SELECT hostName() FROM remote('{clickhouse-0|clickhouse-1|clickhouse-2}.clickhouse-headless', system.one) SETTINGS load_balancing='first_or_random'
"
```

### 8-3. `round_robin`은 반드시 영구 Distributed 테이블로 테스트할 것

`remote()` 테이블 함수는 호출마다 새 커넥션 풀을 생성하므로 회전(rotation) 상태가
유지되지 않습니다. 진짜 회전을 보려면 이미 만들어 둔 Distributed 테이블(`events`)로
테스트해야 합니다.

```bash
for i in $(seq 1 12); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
  SELECT DISTINCT hostName() FROM events SETTINGS load_balancing='round_robin'
  " | grep "^clickhouse-"
done
```

### 8-4. 결과 요약

| 정책 | 관찰된 동작 |
|---|---|
| `in_order` | 항상 목록의 첫 번째 레플리카만 고정 선택 |
| `random` (기본값) | 균등 무작위 분산 |
| `nearest_hostname` | 쿼리를 실행한 노드 자기 자신과 이름이 같은 레플리카를 항상 우선 |
| `round_robin` | 영구 Distributed 테이블의 클러스터 커넥션 풀에서만 진짜로 회전 |
| `first_or_random` | 정상 상태에서는 `in_order`와 동일, 장애 시에만 무작위 폴백 |

### 8-5. `first_or_random` 실제 장애 폴백 데모

7절에서 설명한 이유로, **`replicas` 스케일로 장기간 내릴 수 있는 건 항상 가장 높은
ordinal**뿐입니다. 그래서 이 데모는 3번째 샤드(`clickhouse-6/7/8`)의 마지막
레플리카(`clickhouse-8`)를 대상으로 합니다(Operator 구성에서 "샤드0의 첫 번째
레플리카"를 썼던 것과 대상만 다를 뿐 원리는 동일합니다).

```bash
# 1) 마지막 레플리카만 다운 (replicas 9→8, ordinal 8만 제거됨)
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=8
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/clickhouse-8 --timeout=60s

# 2) in_order — 죽지 않은 나머지 중 "다음 순서"인 clickhouse-6으로 결정론적으로 고정
for i in $(seq 1 8); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{clickhouse-6|clickhouse-7|clickhouse-8}.clickhouse-headless', system.one) SETTINGS load_balancing='in_order'
  "
done

# 3) first_or_random — 살아있는 나머지(6, 7) 사이에서 무작위 분산
for i in $(seq 1 10); do
  kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q "
  SELECT hostName() FROM remote('{clickhouse-6|clickhouse-7|clickhouse-8}.clickhouse-headless', system.one) SETTINGS load_balancing='first_or_random'
  "
done | sort | uniq -c

# 4) 복구
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=9
```

`in_order`는 매번 `clickhouse-6`으로 고정되고, `first_or_random`은 살아있는 `6`/`7`
사이에서 무작위로 분산되는 것을 확인할 수 있습니다.

---

## 9. 샤드 전체 장애 시나리오

레플리카 장애(같은 샤드 내 다른 레플리카로 자동 우회)와 달리, **샤드 전체**가 죽으면
그 샤드가 담당하는 데이터 자체를 조회할 방법이 없습니다. 마침 3번째 샤드
(`clickhouse-6/7/8`)가 StatefulSet의 마지막 3개 ordinal이라, `replicas=6`으로
스케일하면 **정확히 그 샤드 하나만** 깔끔하게 내릴 수 있습니다.

```bash
# 1) 샤드3(clickhouse-6/7/8)의 3개 레플리카 전부 다운
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=6
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/clickhouse-8 --timeout=60s

# 2) 기본 설정 — 에러로 실패해야 함
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM events"
# => Code: 279 ALL_CONNECTION_TRIES_FAILED

# 3) skip_unavailable_shards=1 — 죽은 샤드를 건너뛰고 나머지로 부분 응답
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "SELECT count() FROM events SETTINGS skip_unavailable_shards=1"

# 4) 복구
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=9
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM events"
```

**핵심**: 레플리카는 "같은 데이터의 여분"이라 자동 폴백이 되지만, 샤드는 "서로 다른
데이터 조각"이라 다른 샤드가 대신 답해줄 수 없습니다.

---

## 10. Keeper 노드 장애 내성 테스트

Keeper 3노드는 Raft 합의를 사용하므로 과반(3개 중 2개)이 살아있어야 쓰기가 가능합니다.
이 구성의 Keeper도 StatefulSet 하나(`clickhouse-keeper`, replicas=3)라 스케일 축소는
높은 ordinal부터 제거되는데, 마침 "1개 다운 → 2개 다운"으로 단계적으로 진행하는 이
실험과 자연스럽게 맞아떨어집니다.

```bash
# 0) baseline: 3/3 정상 상태에서 insert
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q \
  "INSERT INTO events VALUES (99001, now(), 'keeper-test-baseline')"

# 1) Keeper 1개 다운 (2/3, 쿼럼 유지) — insert 정상 동작해야 함
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse-keeper --replicas=2
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/clickhouse-keeper-2 --timeout=60s
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q \
  "INSERT INTO events VALUES (99002, now(), 'keeper-test-2of3')"   # 성공

# 2) Keeper 2번째까지 다운 (1/3, 쿼럼 상실)
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse-keeper --replicas=1
kubectl --context kind-clickhouse-lab -n clickhouse wait --for=delete pod/clickhouse-keeper-1 --timeout=60s

# 3) ReplicatedMergeTree 로컬 테이블에 직접 insert 시도
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q \
  "INSERT INTO events_local VALUES (99004, now(), 'direct-keeper-test')"
# => 응답 없이 멈춤 (에러로 즉시 실패하지 않고 쿼럼이 돌아올 때까지 대기)

# 4) (다른 터미널에서) Keeper 2개 복구 → 쿼럼 재형성
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse-keeper --replicas=3

# 5) 위 3)번에서 멈춰있던 insert가 자동으로 완료됨
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-1 -- clickhouse-client -q "SELECT count() FROM events_local WHERE id=99004"
```

**핵심 발견**: Keeper 1노드 장애(2/3 유지)는 완전히 투명하지만, 과반 상실(1/3)이
되면 `ReplicatedMergeTree`로의 직접 INSERT가 에러 없이 그냥 멈추고, 쿼럼이 돌아오면
자동으로 완료됩니다. `Distributed` 테이블 INSERT는 기본 비동기라 겉보기엔 즉시
성공한 것처럼 보이므로, 반드시 `*_local` 테이블에 직접 써서 확인해야 합니다.

---

## 11. 모니터링 (Prometheus + Grafana) 연동

이 구성에는 Altinity Operator가 없으므로, Operator 자체가 노출하던 메트릭(8888 포트,
`chi_clickhouse_event_*`)은 애초에 존재하지 않습니다. ClickHouse 내장 Prometheus
익스포터만으로 관찰합니다.

### 11-1. ClickHouse 내장 Prometheus 익스포터 활성화

`clickhouse-config.yaml` ConfigMap에 새 키를 추가합니다(기존 `cluster.yaml`/
`server.yaml`과 같은 ConfigMap):

```yaml
  prometheus.yaml: |
    prometheus:
      endpoint: /metrics
      port: 9363
      metrics: true
      events: true
      asynchronous_metrics: true
      status_info: true
```

`clickhouse-statefulset.yaml`의 `volumeMounts`에도 이 키를 마운트하는 항목을
추가해야 합니다(`subPath: prometheus.yaml` → `/etc/clickhouse-server/config.d/prometheus.yaml`).

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-config.yaml
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-statefulset.yaml
```

> **주의**: `config.d`에 새 파일이 추가되는 변경은 ClickHouse가 즉시 핫리로드하지
> 못합니다. Operator라면 자동으로 순차 재시작을 걸어주지만, 이 구성은 우리가 직접
> 트리거해야 합니다:
>
> ```bash
> kubectl --context kind-clickhouse-lab -n clickhouse rollout restart statefulset/clickhouse
> kubectl --context kind-clickhouse-lab -n clickhouse rollout status statefulset/clickhouse
> ```
>
> 이 StatefulSet에는 readinessProbe가 없으므로(매니페스트 자체의 한계, 14절 참고),
> `rollout status`가 "완료"라고 보고해도 실제로 ClickHouse가 쿼리를 받을 준비가
> 됐는지는 별도로 확인하는 게 안전합니다.

확인:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- wget -qO- localhost:9363/metrics | head
```

### 11-2. Prometheus 배포 (파드 자동 디스커버리)

파드 레이블이 `clickhouse.altinity.com/chi=chi`가 아니라 **`app: clickhouse`**
(StatefulSet 매니페스트의 `template.metadata.labels`)라는 점만 다르고, 나머지
`manifests/monitoring/prometheus.yaml` 구성 방식은 동일합니다. `kubernetes_sd_configs`
(role: pod)의 relabel 조건을 `app=clickhouse`로 맞춰서 배포합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/monitoring/prometheus.yaml
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/prometheus 9090:9090
# 다른 터미널에서
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health}'
```

Operator 메트릭 job은 아예 없으므로, 이 구성에서 기대되는 타겟 수는 **ClickHouse
파드 9개뿐**입니다(Operator 구성의 "오퍼레이터 1개 + 파드 9개 = 10개"와 다름).

### 11-3. Grafana 배포

`manifests/monitoring/grafana.yaml`은 Operator 구성과 동일하게 재사용할 수 있습니다
(Prometheus를 데이터소스로 프로비저닝하는 부분은 오퍼레이터 유무와 무관). 단, 이후
12절의 대시보드 패널 중 **Operator 관련 패널(Operator Up, Operator Query Events by
Host)은 이 구성에 해당 데이터 소스가 없으므로 제외**합니다.

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/monitoring/grafana.yaml
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/grafana 3000:3000
```

### 11-4. 핵심 정리

- Operator가 없으므로 Operator 자체 메트릭(8888)은 존재하지 않음 — ClickHouse 내장
  익스포터(9363)가 유일한 메트릭 소스.
- `config.d`에 새 파일을 추가하는 변경은 Operator 구성과 마찬가지로 파드 재시작이
  필요하지만, 그 재시작을 **자동으로 걸어주는 주체가 없으므로 직접
  `rollout restart`를 실행**해야 함.
- readinessProbe가 없는 이 매니페스트에서는 "재시작 완료"와 "실제로 쿼리를 받을
  준비가 됨"이 다를 수 있다는 점을 항상 염두에 둘 것(14절에서 다시 다룸).

---

## 12. 가시성 (Observability)

### 12-1. `system.*` 쿼리 치트시트

아래 쿼리들은 오퍼레이터 유무와 무관한 ClickHouse 자체 기능이라 그대로 재사용합니다.

```sql
-- 샤드/레플리카 구성 한눈에 보기
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num;

-- 복제 상태
SELECT database, table, replica_name, is_readonly, is_session_expired,
       active_replicas, total_replicas, log_pointer, log_max_index
FROM system.replicas;

SELECT count() FROM system.replication_queue;
SELECT count() FROM system.detached_parts;

-- Mutation / Merge 진행 상황
SELECT database, table, mutation_id, command, is_done, parts_to_do
FROM system.mutations WHERE NOT is_done;
SELECT count() FROM system.merges;
SELECT table, count() AS parts, sum(rows) AS rows
FROM system.parts WHERE active GROUP BY table;

-- 쿼리 활동 / 저장공간
SELECT count() FROM system.query_log WHERE event_time > now() - INTERVAL 5 MINUTE;
SELECT name, path, free_space, total_space FROM system.disks;

-- Keeper(ZooKeeper) 연결 상태
SELECT * FROM system.zookeeper_connection;
```

### 12-2. Grafana 대시보드 패널 (Operator 패널 제외)

| 패널 | 쿼리 | 비고 |
|---|---|---|
| CH Pods Up | `sum(up{job="clickhouse-pods"})` | 기대값 9 (Operator 구성은 12) |
| Readonly Replicas | `sum(ClickHouseMetrics_ReadonlyReplica)` | 0이 정상 |
| ZooKeeper/Keeper Sessions | `sum(ClickHouseMetrics_ZooKeeperSession)` | 파드 수(9)와 일치해야 함 |
| Cluster Topology (표) | `ClickHouse_Info` | 9개 시계열 |
| Background Activity | `sum(ClickHouseMetrics_Merge)` / `PartMutation` / `ReplicatedFetch` | 클러스터 전체 합산 |
| Query Rate per Pod | `rate(ClickHouseProfileEvents_Query[1m])` | 파드별 9개 라인 |
| Parts by State | `sum by (part_state) (ClickHouseDimensionalMetrics_merge_tree_parts)` | |

> ~~Operator Up~~, ~~Operator Query Events by Host~~ 패널은 이 구성에 Operator가
> 없으므로 제외합니다.

### 12-3. 장애/이상 징후 판별 기준

| 신호 (쿼리/명령) | 정상일 때 | 이상 발생 시 (해당 절) |
|---|---|---|
| `system.replicas.active_replicas` vs `total_replicas` | 두 값이 같음 | PVC를 잃으면 즉시 감소 (7-2절) |
| `system.replicas.is_readonly` | 0 | Keeper 쿼럼 상실 시 읽기 전용 전환, 쓰기 멈춤 (10절) |
| `system.mutations.is_done` + `parts_to_do` | 곧 1로 완료 | 배경 병합이 멈추면 무기한 정체 (16절) |
| `system.replication_queue` 건수 | 0에 가까움 | 대량 리샤딩 직후 일시 급증 (13절) |
| `system.parts`의 테이블당 파트 수 | 적고 안정적 | 단일 파트 테이블은 `OPTIMIZE FINAL`도 건너뛸 수 있음 (16절) |
| Keeper `mntr`의 `zk_server_state` | 리더 1 + 팔로워 나머지 | 네트워크 파티션 중 소수파가 일시적으로 "가짜 리더" 상태일 수 있음 (17절) |

### 12-4. 핵심 정리

- `system.*` 쿼리는 스냅샷에, Grafana는 추세 관찰에 강함 — 둘을 함께 사용.
- Operator가 없다는 것은 "Operator 자체가 집계해주던 클러스터 메트릭"도 없다는
  뜻입니다 — Operator 구성에서는 예상 밖의 수확이었던 "Operator 메트릭만으로도
  상당 부분 관찰 가능"이라는 장점이 이 구성에는 적용되지 않습니다.

---

## 13. 클러스터 확장 & 리샤딩 (3→4 샤드)

ClickHouse는 **샤드를 늘려도 기존 데이터를 자동으로 재분배하지 않습니다.** Operator
구성은 `chi.yaml`의 `shardsCount`만 바꾸면 됐지만, 이 구성은 ConfigMap과
StatefulSet의 `replicas`를 **직접** 수정해야 합니다.

### 13-1. 샤드 확장 (수동)

`manifests/clickhouse-config.yaml`의 `remote_servers.cluster1`에 4번째 샤드
블록을 추가합니다(`clickhouse-9/10/11.clickhouse-headless`).

```yaml
          - internal_replication: true
            replica:
              - host: clickhouse-9.clickhouse-headless
                port: 9000
              - host: clickhouse-10.clickhouse-headless
                port: 9000
              - host: clickhouse-11.clickhouse-headless
                port: 9000
```

```bash
kubectl --context kind-clickhouse-lab apply -f manifests/clickhouse-config.yaml

# StatefulSet을 9 -> 12로 확장 (ordinal 9/10/11은 initContainer가 자동으로
# shard=04, replica=01/02/03을 계산함 — SHARD=ORDINAL/3+1 공식이 그대로 확장됨)
kubectl --context kind-clickhouse-lab -n clickhouse scale statefulset clickhouse --replicas=12
kubectl --context kind-clickhouse-lab -n clickhouse get pods -w   # clickhouse-9/10/11 Running 대기
```

> **주의**: ConfigMap 변경은 이미 떠 있던 `clickhouse-0`~`8`에도 (kubelet의 ConfigMap
> 볼륨 동기화 주기만큼 지연되어) 결국 반영되지만, ClickHouse 프로세스가 이를
> 핫리로드하는지는 별도 확인이 필요합니다. Operator 구성은 이런 클러스터 토폴로지
> 변경 시 기존 파드까지 **자동으로 순차 재시작**시켜주지만, 이 구성엔 그 자동화가
> 없으므로 안전하게 확인하려면 기존 9개도 함께 재시작합니다:
> ```bash
> kubectl --context kind-clickhouse-lab -n clickhouse rollout restart statefulset/clickhouse
> ```
>
> ⚠️ PVC 용량이 Pod당 2Gi로 작게 잡혀 있습니다(`clickhouse-statefulset.yaml`).
> 아래 부하 테스트(15절)처럼 큰 데이터를 다루기 전에 이 용량으로 충분한지 미리
> 계산해 두세요.

### 13-2. 검증: 기존 데이터는 그대로, 새 데이터만 4개 샤드로 분산

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='cluster1' ORDER BY shard_num, replica_num FORMAT PrettyCompact"
# 12 host(4샤드x3레플리카) 확인

# 새 샤드(shard4)는 비어 있어야 함
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-9 -- clickhouse-client -q "SELECT count() FROM events_local"
# => 0

# 새 데이터 삽입 (id >= 100000)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
INSERT INTO events SELECT number+100000, now(), concat('payload-', toString(number)) FROM numbers(4000)
"

for pod in clickhouse-0 clickhouse-3 clickhouse-6 clickhouse-9; do
  echo "--- $pod ---"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT countIf(id<100000) AS old_data, countIf(id>=100000) AS new_data FROM events_local"
done
```

기존 데이터는 shard1~3에 그대로 남고, 새로 삽입한 4000행만 4개 샤드에 고르게
분산되는 것이 확인되어야 합니다(정확한 수치는 `rand()` 분배라 매번 달라짐).

### 13-3. 수동 리샤딩: 기존 데이터 재분배

```bash
# 1) shard1(clickhouse-0)의 old_data 중 절반(짝수 id)을 Distributed로 재삽입
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
INSERT INTO events SELECT id, event_time, payload FROM events_local WHERE id < 100000 AND id % 2 = 0
"

# 2) 원본에서 방금 재삽입한 행 삭제 (mutation, 비동기)
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
ALTER TABLE events_local DELETE WHERE id < 100000 AND id % 2 = 0
"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "SELECT count() FROM system.mutations WHERE table='events_local' AND is_done=0"   # 0이 될 때까지 대기

# 3) 총합 불변 확인
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM events"
```

> ⚠️ **StatefulSet을 다시 9로 줄이지 마세요.** `replicas`를 낮추면 초과된 ordinal
> (9/10/11)의 Pod가 삭제되고, PVC는 `volumeClaimTemplate` 특성상 **자동으로는
> 삭제되지 않지만** 다시 늘렸을 때 그 PVC를 재사용할지, 아니면 원래 있던 데이터가
> 고아 상태로 남을지는 실제로 검증이 필요합니다. 리샤딩으로 shard4에 실제 데이터가
> 들어간 상태이므로, 축소 전 반드시 데이터를 먼저 다른 샤드로 옮기거나 백업하세요.

### 13-4. 핵심 정리

- 샤드 추가는 미래 데이터의 분산 범위만 넓힐 뿐, 과거 데이터는 그대로 둔다 —
  Operator 유무와 무관한 ClickHouse 자체 특성.
- 이 구성에서 샤드 확장은 **ConfigMap 수정 + StatefulSet replicas 확장 + 기존
  파드 수동 재시작**의 3단계이며, Operator 구성처럼 한 번의 `apply`로 전부
  자동 처리되지 않는다.
- initContainer의 `SHARD=ORDINAL/3+1` 공식 덕분에 ordinal만 늘리면 매크로는
  자동으로 올바르게 계산된다.

---

## 14. 무중단 롤링 업그레이드

Operator 구성은 `podTemplate.image`로 태그를 바꾸면 오퍼레이터가 순차 재기동을
자동으로 트리거했습니다. 이 구성은 오퍼레이터가 없으므로 Kubernetes StatefulSet
자체의 기본 롤링 업데이트 메커니즘을 직접 사용합니다.

### 14-1. 현재 버전 확인 (baseline)

매니페스트가 `image: clickhouse/clickhouse-server:latest`로 태그를 고정하지 않고
있으므로, 먼저 지금 실제로 떠 있는 버전이 무엇인지 확인해 베이스라인으로 삼습니다.

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT version()"
```

### 14-2. 이미지 태그를 명시적으로 바꿔 업그레이드 트리거

```bash
kubectl --context kind-clickhouse-lab -n clickhouse set image statefulset/clickhouse \
  clickhouse=clickhouse/clickhouse-server:26.9

kubectl --context kind-clickhouse-lab -n clickhouse rollout status statefulset/clickhouse
```

StatefulSet의 기본 업데이트 전략(`RollingUpdate`, `podManagementPolicy: OrderedReady`)은
**가장 높은 ordinal부터** 한 번에 하나씩 교체합니다(Operator의 "1~2개씩 순차 교체"와
유사하지만 항상 역순 ordinal이라는 점이 다름).

### 14-3. ⚠️ readinessProbe가 없다는 것의 실제 의미

이 매니페스트(`clickhouse-statefulset.yaml`)에는 **liveness/readiness probe가
정의돼 있지 않습니다.** Kubernetes는 probe가 없으면 컨테이너 프로세스가 시작된
순간 곧바로 "Ready"로 간주합니다 — 즉 `RollingUpdate`가 "다음 Pod로 넘어가도 되는
시점"을 **ClickHouse가 실제로 쿼리를 받을 준비가 됐는지**가 아니라 **컨테이너
프로세스가 떴는지**만으로 판단합니다. ClickHouse 시작~쿼리 수신 가능 사이에는
디스크의 파트 로딩 등으로 실제 공백이 있을 수 있으므로, 이 구성의 롤링
업데이트는 Operator 구성보다 "무중단"을 덜 엄격하게 보장합니다.

**개선 방법(권장)**: `clickhouse-statefulset.yaml`의 컨테이너에 아래와 같은
readinessProbe를 추가하면 이 문제를 해결할 수 있습니다.

```yaml
          readinessProbe:
            httpGet:
              path: /ping
              port: 8123
            initialDelaySeconds: 5
            periodSeconds: 5
```

### 14-4. 다운그레이드는 지원되지 않는다 (버전/오케스트레이션 방식 무관)

ClickHouse는 한 번이라도 최신 온디스크 포맷(마크 파일, `system.metric_log` 등)으로
쓰면 예전 바이너리로 되돌아갈 수 없습니다 — 이는 Operator/StatefulSet 어느 쪽으로
배포하든 동일한 ClickHouse 서버 자체의 제약입니다. 롤백은 이미지 태그를 되돌리는
것으로는 불가능하고 스냅샷/백업 복원이 필요합니다.

### 14-5. 가용성 측정 시 `port-forward`의 함정

`kubectl port-forward`는 Service 뒤의 **특정 Pod 하나에 고정**되므로, 그 Pod가
롤링 재시작으로 죽으면 터널이 끊기고 자동 재연결되지 않습니다. 이는 kubectl
자체의 동작이라 Operator 구성과 이 구성 모두 동일하게 적용됩니다. 가용성을
측정하려면 재시작 대상이 아닌 안정적인 Pod에서 `kubectl exec`로 반복 쿼리하거나,
재연결 로직이 있는 클라이언트를 사용해야 합니다.

### 14-6. 핵심 정리

| 항목 | Operator 구성 | 이 구성 |
|---|---|---|
| 업그레이드 트리거 | `chi.yaml`의 `podTemplate.image` 수정 | `kubectl set image statefulset/...` |
| 롤아웃 순서 | Operator가 1~2개씩 순차 | K8s 기본 `RollingUpdate`, 역순 ordinal로 하나씩 |
| 준비 상태 판단 | Operator의 자체 헬스체크 | **probe 없음 — 컨테이너 시작만으로 Ready 판단(개선 필요)** |
| 다운그레이드 | 미지원 | 미지원 (ClickHouse 자체 제약, 동일) |

---

## 15. 부하 테스트 & `max_parallel_replicas` 실험

`max_parallel_replicas`는 **같은 샤드 안의 여러 레플리카**가 하나의 쿼리를 나눠서
함께 스캔하게 만드는 설정입니다. 이 구성은 3샤드이므로 수치만 원본(4샤드)과
다를 뿐 방법론은 동일합니다.

### 15-1. 벤치마크용 데이터셋 준비

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
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

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
CREATE TABLE bench ON CLUSTER 'cluster1' AS bench_local
ENGINE = Distributed('cluster1', currentDatabase(), bench_local, rand())
"

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client --max_insert_threads=4 -q "
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

3샤드에 걸쳐 총 1,000만 행(샤드당 약 333만 행)이 적재됩니다. **PVC가 2Gi뿐이므로
디스크 여유를 미리 `system.disks`로 확인**하세요(13절에서 지적한 용량 제약).

### 15-2. `enable_parallel_replicas` 설정

```sql
SELECT name, value, description FROM system.settings WHERE name ILIKE '%parallel_replicas%'
```

`max_parallel_replicas`만으로는 효과가 없고 `enable_parallel_replicas=1`을 함께
켜야 합니다. 로컬 테이블에 직접 걸면 `Code: 701`(`cluster_for_parallel_replicas`
필요) 에러가, `cluster_for_parallel_replicas='cluster1'`을 지정하면 `Code: 714`
(샤드가 여러 개라 불가) 에러가 납니다 — **Distributed 테이블(`bench`)에 대고
쿼리해야** `cluster_for_parallel_replicas` 없이 바로 동작합니다.

```sql
SELECT category, count(), avg(val1), avg(val2), sum(length(payload))
FROM bench WHERE val1 > 0 GROUP BY category
SETTINGS enable_parallel_replicas=1, max_parallel_replicas=3
```

### 15-3. 병렬 읽기 발동 여부 확인

```bash
for pod in clickhouse-0 clickhouse-1 clickhouse-2; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q "SYSTEM FLUSH LOGS"
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT count() FROM system.query_log WHERE initial_query_id='<쿼리ID>'"
done
```

### 15-4. 성능 비교

```bash
clickhouse-benchmark -i 60 -c 2 --query "SELECT category, count(), avg(val1), avg(val2), sum(length(payload)) FROM bench WHERE val1 > 0 GROUP BY category"
clickhouse-benchmark -i 60 -c 2 --query "... SETTINGS enable_parallel_replicas=1, max_parallel_replicas=3"
```

**예상 경향**(GUIDE.md 15절, 동일한 물리 환경에서 실측한 원 실험 참고): 이 랩의
모든 Pod는 결국 하나의 Colima VM(6 vCPU)을 나눠 쓰는 kind 워커 컨테이너이므로,
"병렬" 레플리카가 실제로는 같은 물리 코어를 두고 경쟁합니다. 레플리카당 스캔량이
크지 않은 이 규모에서는 조율 오버헤드가 병렬화 이득을 상쇄해 `max_parallel_replicas`가
오히려 느려지는 결과가 나올 가능성이 높습니다 — 원 실험(4샤드 기준)과 동일한
근본 원인(물리 코어 공유)이 3샤드 구성에도 그대로 적용되기 때문입니다.

### 15-5. 정리

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "DROP TABLE IF EXISTS bench ON CLUSTER 'cluster1' SYNC"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "DROP TABLE IF EXISTS bench_local ON CLUSTER 'cluster1' SYNC"
```

---

## 16. Mutation & TTL 라이프사이클

이 절은 순수 ClickHouse SQL 동작이라 Operator 유무와 무관하게 동일합니다. Pod
이름만 이 구성(`clickhouse-0`~`8`)에 맞춥니다.

### 16-1. Mutation 전파 (비동기 vs 동기)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' UPDATE payload = concat('updated-', toString(id)) WHERE id % 3 = 0
"

for pod in clickhouse-0 clickhouse-1 clickhouse-2 clickhouse-3 clickhouse-4 clickhouse-5 clickhouse-6 clickhouse-7 clickhouse-8; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- clickhouse-client -q \
    "SELECT count() FROM system.mutations WHERE table='events_local' AND NOT is_done"
done

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' UPDATE payload = concat('updated2-', toString(id)) WHERE id % 3 = 1
SETTINGS mutations_sync=2
"

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
ALTER TABLE events_local ON CLUSTER 'cluster1' DELETE WHERE id % 3 = 2
"
```

### 16-2. TTL은 "시간이 되면 자동으로" 지워지지 않는다

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
CREATE TABLE ttl_demo_local ON CLUSTER 'cluster1'
(
    id UInt64,
    inserted_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/ttl_demo_local', '{replica}')
ORDER BY id
TTL inserted_at + INTERVAL 30 SECOND
"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
CREATE TABLE ttl_demo ON CLUSTER 'cluster1' AS ttl_demo_local
ENGINE = Distributed('cluster1', currentDatabase(), ttl_demo_local, rand())
"

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "
INSERT INTO ttl_demo_local VALUES
  (1, now() - INTERVAL 1 MINUTE), (2, now() - INTERVAL 1 MINUTE),
  (3, now() - INTERVAL 1 MINUTE), (4, now() - INTERVAL 1 MINUTE),
  (5, now())
"
```

TTL 기준을 한참 넘겨도(`OPTIMIZE ... FINAL`까지 포함해) 사라지지 않을 수 있습니다.
확실히 강제하려면:

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "ALTER TABLE ttl_demo_local ON CLUSTER 'cluster1' MATERIALIZE TTL"

kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "SELECT is_done, parts_to_do FROM system.mutations WHERE table='ttl_demo_local'"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT * FROM ttl_demo_local ORDER BY inserted_at"
```

### 16-3. 정리

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "DROP TABLE IF EXISTS ttl_demo ON CLUSTER 'cluster1' SYNC"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "DROP TABLE IF EXISTS ttl_demo_local ON CLUSTER 'cluster1' SYNC"
```

### 16-4. 핵심 정리

| 항목 | 결과 |
|---|---|
| 비동기 mutation | 명령 즉시 리턴, `system.mutations.is_done`을 폴링해 완료 확인 |
| 동기 mutation (`mutations_sync=2`) | 클라이언트가 클러스터 전체 완료까지 블로킹 |
| TTL 만료 트리거 | 오직 병합(또는 `MATERIALIZE TTL`) 시점에만 평가 |
| 단일 파트 테이블의 함정 | `OPTIMIZE ... FINAL`도 건너뛸 수 있음 → `MATERIALIZE TTL`이 확실한 강제 수단 |

---

## 17. 네트워크 파티션 (스플릿 브레인) 시뮬레이션

> ⚠️ **이 실험은 리스크가 높습니다.** 노드 레벨에서 iptables 규칙을 직접
> 조작하므로, 제거 명령을 미리 적어두고 파티션 유지 시간을 짧게 제한한 뒤
> 곧바로 원복 → 연결 확인 → 헬스체크 순서를 지키세요.

10절은 Keeper 프로세스 자체를 스케일로 죽이는 방식이었습니다. 이번엔 **프로세스는
살아있는 채로 네트워크만 끊어서** 스플릿 브레인 상황을 재현하고, 파티션 해제 후
사람 개입 없이 자동 재합류하는지 확인합니다. Keeper Pod 이름만
`clickhouse-keeper-0/1/2`로 바뀔 뿐 원리와 도구(kind 노드 컨테이너 안 iptables)는
동일합니다.

### 17-1. 토폴로지 확인

```bash
kubectl --context kind-clickhouse-lab -n clickhouse get pods -o wide | grep keeper
kubectl --context kind-clickhouse-lab get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

> Pod가 실제로 어느 kind 노드에 배치됐는지, 그래서 몇 대 몇으로 분할할 수
> 있는지는 이 구성에서 새로 확인해야 합니다(원 실험의 2:1 배치가 그대로
> 재현된다는 보장은 없음).

### 17-2. 파티션 적용 → 관찰 → 즉시 원복

```bash
# <워커N>, <워커M>은 위에서 확인한 실제 노드 이름으로 치환
docker exec clickhouse-lab-<워커N> iptables -I FORWARD -s <CIDR-M> -d <CIDR-N> -j DROP
docker exec clickhouse-lab-<워커N> iptables -I FORWARD -s <CIDR-N> -d <CIDR-M> -j DROP
docker exec clickhouse-lab-<워커M> iptables -I FORWARD -s <CIDR-N> -d <CIDR-M> -j DROP
docker exec clickhouse-lab-<워커M> iptables -I FORWARD -s <CIDR-M> -d <CIDR-N> -j DROP

# 양쪽의 Keeper 4-letter-word 상태 확인
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-keeper-0 -- sh -c "echo mntr | nc -w2 127.0.0.1 2181"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-keeper-2 -- sh -c "echo mntr | nc -w2 127.0.0.1 2181"

# 다수파를 거쳐 쓰기가 되는지 확인
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q \
  "INSERT INTO events_local VALUES (999001, now(), 'partition-test-majority')"

# 곧바로 규칙 제거 (위 4개 iptables -I 를 각각 -D 로)
```

원 실험(GUIDE.md 17절)에서는 파티션 직후 짧은 관찰 창 안에서 소수파 쪽이 아직
팔로워 단절을 감지하지 못해 스스로를 "리더"라고 오보고하는 과도기 상태가
관찰됐습니다 — 같은 Raft 구현이므로 이 구성에서도 재현될 가능성이 높지만, 실제
노드 배치가 다를 수 있으므로 직접 확인이 필요합니다.

### 17-3. 원복 후 자동 자가치유 확인

```bash
for pod in clickhouse-keeper-0 clickhouse-keeper-1 clickhouse-keeper-2; do
  kubectl --context kind-clickhouse-lab -n clickhouse exec $pod -- sh -c "echo mntr | nc -w2 127.0.0.1 2181" | grep zk_server_state
done
```

파티션 해제 후 **아무 명령도 실행하지 않고** 3노드 Raft 앙상블이 스스로 리더/팔로워를
재정립하는지 확인합니다 — 10절(프로세스 종료, 수동 개입 필요)과 대비되는 지점입니다.

### 17-4. 사후 검증

```bash
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM system.clusters WHERE cluster='cluster1'"
kubectl --context kind-clickhouse-lab -n clickhouse exec clickhouse-0 -- clickhouse-client -q "SELECT count() FROM events"
```

---

## 18. 접속 (호스트에서 직접 붙어보기)

```bash
kubectl --context kind-clickhouse-lab -n clickhouse port-forward svc/clickhouse-headless 8123:8123 9000:9000
# 다른 터미널에서
clickhouse-client --host 127.0.0.1
# 또는
curl 'http://localhost:8123/?query=SELECT%201'
```

`clickhouse-headless`는 헤드리스 서비스(`clusterIP: None`)지만, `kubectl
port-forward`는 서비스 뒤의 특정 Pod를 골라 직접 연결하므로 문제없이 동작합니다.

---

## 19. 정리

이 구성만 걷어내고(Operator 기반 클러스터나 kind 클러스터 자체는 유지하고 싶다면):

```bash
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/clickhouse-statefulset.yaml
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/clickhouse-service.yaml
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/clickhouse-config.yaml
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/keeper-statefulset.yaml
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/keeper-service.yaml
kubectl --context kind-clickhouse-lab -n clickhouse delete -f manifests/keeper-config.yaml
# PVC는 StatefulSet 삭제로 자동 삭제되지 않으므로 필요 시 별도 삭제
kubectl --context kind-clickhouse-lab -n clickhouse delete pvc -l app=clickhouse
kubectl --context kind-clickhouse-lab -n clickhouse delete pvc -l app=clickhouse-keeper
```

kind 클러스터 자체를 통째로 정리하려면:

```bash
kind delete cluster --name clickhouse-lab
```

(Colima 리소스를 원래대로 되돌리려면 `colima stop && colima start --cpu 4 --memory 8`)

> **주의**: 이 랩의 다른 실험(GUIDE.md의 Operator 기반 4샤드×3레플리카 클러스터,
> Redpanda 등)과 **같은 `clickhouse` 네임스페이스를 공유**합니다. 두 구성을 동시에
> 띄우면 (9~12 + 12개, 최대 24개) Pod가 공유 Colima VM(6 vCPU/16GB) 자원을 두고
> 경쟁하게 되므로, 이 가이드를 시작하기 전에 기존 클러스터를 먼저 정리했는지
> 확인하세요.
