# ClickHouse on AWS 운영 가이드

[PRODUCTION.md](./PRODUCTION.md)의 원칙을 AWS(주로 EKS + Altinity 오퍼레이터 기준,
필요한 곳은 순수 EC2 자체 관리도 함께 언급)에 구체적으로 적용하는 문서입니다.
PRODUCTION.md의 일반 원칙은 반복하지 않고, **"AWS에서는 구체적으로 무엇을
선택/설정해야 하는가"**에 집중합니다. 각 절은 PRODUCTION.md의 대응 절 번호를
함께 표시했습니다.

> 인스턴스 타입/서비스명 등은 시간이 지나면 바뀝니다. 배포 직전에 AWS 공식
> 문서로 최신 세대/이름을 다시 확인하세요.

---

## 1. 컴퓨트 — EC2 인스턴스 선택 (PRODUCTION.md 1절)

| 워크로드 성격 | 권장 계열 | 비고 |
|---|---|---|
| 대용량 스토리지 + 높은 스캔 처리량 | `i7i`(최신 세대, NVMe 최대 45TB) 또는 `i4i` | 로컬 NVMe가 EBS보다 지연시간이 낮고 저렴 — 단, **인스턴스 종료/중지 시 데이터가 사라지므로 반드시 3레플리카 이상과 조합** |
| CPU 바운드(무거운 집계/조인) | `c6i`/`c7i` + gp3/io2 | 스토리지는 EBS로 분리, 컴퓨트만 스케일 |
| 범용/메모리 바운드 | `r6i`/`r7i` + gp3/io2 | 캐시(mark cache, uncompressed cache)가 큰 워크로드 |
| 비용 최적화 | Graviton(ARM) `r8g`/`c8g`/`m8g` | ClickHouse는 ARM 빌드를 공식 지원 — 동급 대비 20~30% 비용 절감 사례가 보고됨. 다만 스토리지 최적화(NVMe) 계열의 Graviton 대응은 상대적으로 덜 성숙하니, 우선 컴퓨트/메모리 바운드 워크로드부터 적용 권장 |

**로컬 NVMe(instance store) vs EBS 선택 기준**: instance store는 지연시간과
비용 면에서 유리하지만 인스턴스 라이프사이클에 종속됩니다. `ReplicatedMergeTree`로
3중 복제를 하고 있다면 "한 인스턴스가 통째로 사라져도 나머지 레플리카가 있다"는
전제가 성립하지만, **운영 난이도가 올라갑니다**(GUIDE.md 7-2절에서 확인했듯,
디스크를 잃은 레플리카는 스키마 재등록 등 수동 개입이 필요). 처음 구축한다면
EBS(gp3)로 시작해 운영 부담을 낮추고, 성능이 병목이 될 때 instance store로
전환하는 순서를 권장합니다.

## 2. 스토리지 — EBS 볼륨 타입 (PRODUCTION.md 1절)

- **gp3(기본 권장)**: 기본 3,000 IOPS / 125 MiB/s가 무료 포함, 최대
  **80,000 IOPS / 2,000 MiB/s**까지 별도 프로비저닝 가능(2026년 기준 상향된
  한도 — 이전 세대 문서에 나오는 16,000 IOPS/1,000 MiB/s는 옛 수치이니
  주의). 대부분의 ClickHouse 워크로드에 충분합니다.
- **io2 Block Express**: gp3보다 더 높은 내구성/IOPS 상한이 필요한 극단적
  워크로드(초대형 단일 볼륨, 매우 높은 랜덤 I/O)에만 고려하세요 — 대부분의
  경우 gp3 다중 볼륨(샤드 늘리기)이 io2 단일 볼륨보다 비용 효율적입니다.
- **Keeper 전용 볼륨은 별도로 작게, 하지만 IOPS는 넉넉하게**: Keeper의
  changelog는 매 쓰기마다 fsync하므로(PRODUCTION.md 2절), 용량보다 IOPS가
  중요합니다. 데이터 노드와 같은 볼륨/노드그룹을 공유하지 마세요.

### EKS StorageClass 예시 (aws-ebs-csi-driver)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: clickhouse-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"          # 워크로드에 맞춰 조정 (iops와 iopsPerGb는 동시 지정 불가)
  throughput: "250"      # MiB/s
  encrypted: "true"      # 반드시 활성화 (KMS 기본 키 또는 커스텀 CMK)
volumeBindingMode: WaitForFirstConsumer   # 파드가 스케줄된 AZ에 맞춰 볼륨 생성 — 필수
allowVolumeExpansion: true
```

`WaitForFirstConsumer`가 핵심입니다 — 이게 없으면 볼륨이 파드보다 먼저 특정
AZ에 생성되어 버리고, 나중에 파드가 다른 AZ로 스케줄되면 **EBS는 AZ에 종속되어
있어 마운트가 실패**합니다. EBS CSI 드라이버 자체는 IRSA(또는 EKS Pod
Identity, 5절 참고)로 `AmazonEBSCSIDriverPolicy`(또는 최신 `...PolicyV2` —
배포 시점에 정확한 이름 확인) 권한이 필요합니다.

## 3. 스키마 설계 / 4. 인서트 전략 / 5. 메모리·동시성 설정 (PRODUCTION.md 3~5절)

이 세 항목은 AWS냐 아니냐와 무관한 ClickHouse 자체 설정이라 PRODUCTION.md
내용이 그대로 적용됩니다. AWS에서 추가로 고려할 점 하나만 덧붙이면:

- **네트워크 대역폭도 인스턴스 사양의 일부입니다.** 같은 vCPU/메모리라도
  인스턴스 크기가 작으면 네트워크 대역폭이 제한되어(AWS는 인스턴스 크기별로
  네트워크 성능을 계단식으로 제공) 대량 배치 INSERT나 리샤딩(GUIDE.md 13절
  같은 재분배 작업)이 예상보다 느릴 수 있습니다. 처리량이 중요한 노드는
  네트워크 등급이 높은 인스턴스 크기를 선택하세요.

## 6. 복제/샤딩 아키텍처 — AZ 배치와 비용 (PRODUCTION.md 6절)

- **레플리카를 서로 다른 AZ에 분산**하는 것이 진짜 고가용성의 핵심입니다 —
  AZ 하나가 통째로 장애 나도(드물지만 실제로 발생) 나머지 AZ의 레플리카가
  서비스를 지속합니다.
- **하지만 공짜가 아닙니다**: AWS는 **AZ 간 트래픽에 요금을 부과**합니다.
  `ReplicatedMergeTree`의 복제 트래픽과 `Distributed` 테이블의 샤드 간 쿼리
  팬아웃이 전부 AZ 간 트래픽이 될 수 있습니다. 샤드 수 × 레플리카 수가 커질수록
  이 비용이 누적되니, 용량 계획 시 데이터 전송 비용도 함께 추정하세요.
- **Keeper도 반드시 AZ 분산**: GUIDE.md 17절/AUDIT.md에서 우리 랩이 실제로
  Keeper 3노드 중 2개가 같은 노드(=현실에선 같은 AZ)에 몰려있던 걸 확인했습니다.
  EKS에서는 이를 `topologySpreadConstraints`로 강제해야 합니다:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone   # 최신 표준 라벨 (구버전 failure-domain.beta.* 아님)
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        clickhouse-keeper.altinity.com/chk: chk
```

이 규칙은 Altinity CHK/CHI 매니페스트의 `spec.templates.podTemplates[].spec`
아래에 넣습니다 — 우리 랩의 `chk.yaml`/`chi.yaml`에는 이 필드가 아예 없었다는
점을 AUDIT.md 1번 항목에서 지적한 바 있습니다.

## 7. 백업 & 재해복구 — S3 연동 (PRODUCTION.md 7절)

네이티브 `BACKUP`/`RESTORE`를 S3로 바로 보낼 수 있습니다:

```sql
BACKUP TABLE events TO S3(
    'https://<bucket>.s3.amazonaws.com/backups/events',
    '<access_key_id>', '<secret_access_key>'
);
```

**주의**: 이 `BACKUP ... TO S3(...)` 구문은 **IAM 역할만으로는 인증할 수
없고 access key/secret key를 명시해야 합니다**(2026년 기준). 즉, IRSA로
파드에 IAM 역할을 붙였다고 해서 `BACKUP` 명령이 자동으로 그 권한을 쓰지는
않습니다 — 키를 평문으로 SQL에 넣지 말고, **named collection**(`config.xml`에
등록해두고 SQL에서는 이름만 참조하는 방식)이나 Secrets Manager에서 가져온
값을 주입하는 방식을 쓰세요.

(참고로 이건 백업과는 별개로, S3를 **디스크로 마운트**해 데이터 자체를
S3 계층으로 티어링하는 구성 — `<use_environment_credentials>true</...>`로
IAM 역할 기반 인증이 가능합니다. 백업 목적지로서의 S3와, 스토리지 계층으로서의
S3는 인증 방식이 다르다는 점을 헷갈리지 마세요.)

- **버킷 정책**: 버저닝 활성화 + Object Lock(랜섬웨어/실수 삭제 대비),
  수명주기 정책으로 오래된 백업을 Glacier로 이관.
- **DR**: 크로스 리전 복제(CRR)로 백업 버킷을 다른 리전에도 복제하고,
  PRODUCTION.md 7절이 강조하듯 **정기적으로 별도 클러스터에 실제 복구 테스트**를
  하세요 — 이건 리전이 바뀌어도 변하지 않는 원칙입니다.
- **NAT 비용 절감**: 백업/복원 트래픽이 크다면 S3 Gateway VPC Endpoint를
  구성해 NAT Gateway를 거치지 않게 하세요 (NAT Gateway의 데이터 처리 요금은
  의외로 큽니다).

## 8. 업그레이드/롤백 (PRODUCTION.md 8절)

- 이미지 태그 고정 원칙은 AWS에서도 동일합니다. 다만 자체 ECR 리포지토리에
  특정 버전을 미러링해두면(퍼블릭 Docker Hub 의존 제거 + 이미지 불변성 보장)
  프로덕션 안정성이 한 단계 더 올라갑니다.
- 다운그레이드 불가 원칙(GUIDE.md 14절에서 직접 재현)도 동일하게 적용됩니다 —
  AWS 환경이라고 예외는 없습니다.

## 9. 모니터링 (PRODUCTION.md 9절)

GUIDE.md 12절에서 만든 자체 호스팅 Prometheus/Grafana를 그대로 EKS에
올려도 되지만, AWS 네이티브 대안도 있습니다:

- **Amazon Managed Prometheus(AMP) + Amazon Managed Grafana(AMG)**: 직접
  Prometheus/Grafana를 운영하고 싶지 않다면 사용. 일반적인 연동 방식은
  (a) 기존처럼 자체 Prometheus를 두고 `remote_write`로 AMP에 흘려보내거나,
  (b) ADOT(AWS Distro for OpenTelemetry) 콜렉터가 직접 스크레이프해서 AMP로
  전송. AMG가 AMP를 데이터소스로 조회합니다.
- 어느 쪽이든 GUIDE.md 12절의 **`system.*` 쿼리 치트시트와 장애 판별 기준
  표는 그대로 재사용**할 수 있습니다 — 바뀌는 건 메트릭을 어디에 저장/조회
  하느냐일 뿐입니다.
- 알람 규칙(AUDIT.md에서 지적한 "관측은 되지만 알림은 안 됨" 공백)은 AMP를
  쓰면 Alertmanager 대신 AMP의 룰 평가 기능을, 자체 호스팅이면
  Prometheus Alertmanager를 반드시 함께 구성하세요.

## 10. 보안 (PRODUCTION.md 10절)

- **IAM — IRSA vs EKS Pod Identity**: 2026년 기준 둘 다 지원되며 IRSA가
  폐기 예정은 아닙니다. 다만 AWS는 **새로 구성하는 EC2 기반 워크로드에는
  Pod Identity를 권장**합니다(설정이 더 단순함). Fargate를 쓴다면 IRSA가
  여전히 필수입니다. 기존에 IRSA로 잘 운영 중이라면 특별한 이유(ABAC, 역할
  이식성, 크로스 계정 접근 등) 없이는 마이그레이션을 서두를 필요는 없습니다.
- **네트워크**: ClickHouse/Keeper 노드는 프라이빗 서브넷에만 배치하고, 보안
  그룹은 필요한 포트(9000/8123/9009, Keeper 2181/9444)를 VPC 내부 CIDR로만
  제한하세요. 퍼블릭 서브넷/퍼블릭 IP는 원칙적으로 불필요합니다.
- **시크릿 관리**: `default` 사용자 빈 비밀번호 금지(AUDIT.md에서 우리 랩이
  실제로 이 상태였음을 확인) — AWS Secrets Manager에 비밀번호를 저장하고
  External Secrets Operator 등으로 K8s Secret에 동기화한 뒤 CHI의 users
  설정에 주입하세요.
- **암호화**: EBS는 반드시 `encrypted: true`(KMS), S3 버킷은 SSE-KMS 기본
  적용.

## 11. EKS 배포 체크리스트 (PRODUCTION.md 11절의 AWS 구체화)

PRODUCTION.md 11절의 일반 K8s 체크리스트에 더해, EKS 한정으로 추가/구체화할
항목:

- [ ] StorageClass가 `ebs.csi.aws.com` 프로비저너, `gp3`, `WaitForFirstConsumer`
      로 설정되어 있는지 (2절)
- [ ] EBS CSI 드라이버가 IRSA 또는 Pod Identity로 정상 권한을 갖고 있는지
- [ ] Keeper/CHI 파드에 `topologySpreadConstraints`(`topology.kubernetes.io/zone`)
      가 실제로 걸려 있고, `kubectl get pods -o wide`로 AZ가 실제 분산됐는지
      확인 (우리 랩에서 이게 없어서 발생한 문제 — AUDIT.md 1번)
- [ ] **오토스케일러(Cluster Autoscaler/Karpenter) 사용 시 stateful 파드
      보호**: PDB(Altinity 오퍼레이터가 자동 생성 — AUDIT.md 5번에서 확인)와
      함께, 노드 축소 시 Keeper/ClickHouse 파드가 함부로 축출되지 않도록
      `safe-to-evict` 어노테이션이나 별도 전용 노드그룹(taint+toleration)으로
      분리하는 걸 권장
- [ ] S3 Gateway VPC Endpoint 구성(백업/S3 디스크 트래픽용, NAT 비용 절감)
- [ ] 리소스 requests/limits이 실제 인스턴스 사양 대비 과다/과소하지 않은지
      (AUDIT.md 4번 — 우리 랩은 이게 아예 없었음)

---

## 요약: AWS 배포 전 최종 체크리스트

1. 워크로드 성격에 맞는 인스턴스 계열 선택(스토리지 i7i/i4i, 컴퓨트 c7i,
   비용 Graviton) — instance store는 EBS보다 운영 부담이 큼을 인지하고 선택
2. gp3 기본(최대 80,000 IOPS/2,000 MiB/s), Keeper는 용량보다 IOPS 우선
3. StorageClass에 `WaitForFirstConsumer` 필수, EBS CSI에 IRSA/Pod Identity 연결
4. Keeper/CH 레플리카를 `topologySpreadConstraints`로 AZ 분산 — 단, AZ 간
   트래픽 비용을 용량 계획에 반영
5. `BACKUP ... TO S3(...)`는 키 인증만 지원 — named collection/Secrets
   Manager로 평문 노출 방지, 버킷 버저닝+수명주기+CRR 구성
6. 이미지는 ECR에 특정 버전으로 미러링해 고정
7. Prometheus/Grafana 자체 호스팅 또는 AMP/AMG — 어느 쪽이든 알람 규칙까지
   구성(대시보드만으로는 부족)
8. Secrets Manager로 사용자 비밀번호 관리, EBS/S3 KMS 암호화, 프라이빗
   서브넷 전용 배치
9. Cluster Autoscaler/Karpenter가 stateful 파드를 함부로 축출하지 않도록
   PDB + 전용 노드그룹으로 보호
