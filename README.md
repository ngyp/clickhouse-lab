# clickhouse-lab

로컬 macOS(Colima + [kind](https://kind.sigs.k8s.io/))에서 [Altinity Kubernetes
Operator for ClickHouse](https://github.com/Altinity/clickhouse-operator)와
ClickHouse Keeper를 이용해 **3샤드 × 3레플리카** ClickHouse 클러스터를 구성하고,
장애 복구·로드밸런싱 동작을 실습하기 위한 실험 환경입니다.

## 구성

- **kind**: control-plane 1 + worker 3 노드 로컬 Kubernetes 클러스터
- **Altinity ClickHouse Operator** (Helm 설치)
- **ClickHouseKeeperInstallation (CHK)**: Keeper 3노드 앙상블 (좌표 조정)
- **ClickHouseInstallation (CHI)**: ClickHouse 3샤드 × 3레플리카 (PVC 기반 영구 스토리지)

```
manifests/
├── kind-config.yaml   # kind 클러스터 정의 (4노드)
├── chk.yaml           # ClickHouseKeeperInstallation (Keeper 3노드)
└── chi.yaml           # ClickHouseInstallation (3샤드 x 3레플리카, PVC 포함)
```

## 시작하기

전체 설치 절차, 검증 방법, 실험 시나리오는 **[GUIDE.md](./GUIDE.md)**를 참고하세요.

```bash
kind create cluster --config manifests/kind-config.yaml
helm repo add altinity https://helm.altinity.com
helm upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace clickhouse --create-namespace
kubectl apply -f manifests/chk.yaml
kubectl apply -f manifests/chi.yaml
```

## 다뤄본 실험

- 샤딩(`Distributed`) + 복제(`ReplicatedMergeTree`) 기본 동작 검증
- 파드 삭제 후 자동 복구: PVC 유지 시 vs. 진짜 디스크 유실 시 차이
- 샤드 전체 다운 시 `skip_unavailable_shards` 동작
- `Distributed` 테이블 `load_balancing` 정책 5종 (`in_order`, `random`,
  `nearest_hostname`, `round_robin`, `first_or_random`) 비교, 장애 시 폴백 동작
- Keeper 노드 장애 내성 (쿼럼 상실 시 쓰기 블로킹, 쿼럼 복구 시 자동 재개)

자세한 명령어와 결과는 [GUIDE.md](./GUIDE.md)에 정리돼 있습니다.
