# AWS ClickHouse 용량·비용 산정안

이 문서는 쇼핑몰 구매 여정 예제를 AWS EKS에서 운영하기 위한 1차 용량 산정안이다.
실험실에서 확인한 결과와 운영 트래픽을 대입한 예상치를 구분하며, 최종 사양은 동일한
스키마·메시지 크기·MV를 사용한 AWS 부하 시험으로 확정한다.

산정 기준일은 2026-10-02이며, 가격은 서울 리전(`ap-northeast-2`) 공개 On-Demand
단가와 월 730시간, 환율 1달러당 1,400원을 가정했다. 실제 청구액은 회사 할인,
환율, 세금, 네트워크 사용량에 따라 달라진다.

## 결론

첫 운영 후보는 다음과 같다.

| 항목 | 시작 사양 |
|---|---|
| ClickHouse | 2 shard × 2 replica |
| Active AZ | 2개 |
| DR AZ | 1개, ClickHouse 데이터 노드 그룹은 평상시 0대 |
| ClickHouse 노드 | `r7i.xlarge` 4대, 노드당 4 vCPU·32GiB |
| 데이터 PVC | gp3 500GiB × 4, 기본 3,000 IOPS·125MiB/s |
| Keeper | 3개, AZ별 1개 상시 실행 |
| Pod 자원 | request 3 vCPU·24GiB, memory limit 28GiB |
| 월 예상 비용 | 약 200만~220만 원 |

평균 유입과 일반 피크에는 적합할 가능성이 높다. 서비스 조회는 원본을 다시 집계하지
않고 누적·시간 Summary를 사용해야 한다. 순간 10배 피크는 Kafka가 버퍼 역할을 하면
대응 가능하지만, 장시간 지속되는 10배 피크는 AWS 부하 시험 결과로 판정한다.

## 배치 구조

```text
평상시

AZ-A                         AZ-B                         AZ-C
shard-1 replica-1            shard-1 replica-2            Keeper-3
shard-2 replica-1            shard-2 replica-2            ClickHouse DR Node Group
Keeper-1                     Keeper-2                     min=0, desired=0, max=2
```

AZ-C 전체가 꺼지는 구성은 아니다. ClickHouse 데이터 노드는 Cold 상태지만 Keeper-3은
quorum을 위해 상시 실행한다. Keeper-3까지 정지하면 평상시 Keeper가 정확히 2개만
남아 개별 Keeper 장애에도 quorum을 잃는다.

AZ-A 또는 AZ-B 장애 시 살아 있는 replica가 조회·적재를 계속하고, AZ-C 데이터 노드
그룹을 2대로 확장하여 replica를 복구한다. EBS 볼륨은 AZ에 종속되므로 장애 AZ의
볼륨을 AZ-C에 직접 연결할 수 없다. 생존 replica의 part 복제 또는 S3 백업 복구가
필요하다.

## 기준 데이터 프로필

### 제공된 업무 기준

아래 값은 용량 계산 과정에서 제공된 실제 업무 규모와 데이터 관계다. 쇼핑몰 예제의
`product_id`는 `placement_id`, `journey_id`는 `tracking_id`,
`customer_group_ids`는 `universe_info_ids`에 대응한다.

| 구분 | 기준 정보 |
|---|---|
| 전체 행동 로그 | 평균 일 2억 건, 고부하 일 최대 4억 건이 Kafka로 유입될 수 있음 |
| 저장 후보 | Kafka Engine MV에서 `tracking_id`가 존재하는 행만 통과 |
| 최대 통과율 | 전체 행동 로그의 약 30% |
| 일반 행동 반응률 | 보통 5% 이하이나 용량은 최대 통과율 30%로 계산 |
| 월 placement | 약 1만~2만 개 생성 예상 |
| 월 tracking ID | 전체 약 1억 개 이내 예상 |
| 관계 | placement 하나에 N개의 tracking ID가 연결됨 |
| 불변 조건 | 하나의 tracking ID에 할당된 placement ID는 변하지 않음 |
| 이벤트 중복 | 같은 tracking ID가 event type별로 반복 수집될 수 있음 |
| 고유 이벤트 키 | `(placement_id, tracking_id, event_type)` |
| 최초 기준 | 이벤트 발생 시각이 아니라 ClickHouse 최초 입수 기준 |
| 누적 조회 | 전체 기간 placement별 event type count |
| 상세 조회 | placement별 event type count를 일·시간대로 구분 |
| 추가 조회 축 | 사전에 정해진 universe 정보별 집계 |
| 응답 목표 | Summary 기반 서비스 조회 1초 이내 |
| API 상한 참고 | 무거운 조회도 10초 timeout 안에 끝나는지 별도 확인 |

입력 경로도 서로 다르다.

| 입력 | 원천 식별 정보 | ClickHouse에서 필요한 처리 |
|---|---|---|
| 행동·클릭 계열 | `placement_id`, `tracking_id`를 직접 포함 | tracking 존재 여부 필터 후 tracking 기준 shard 라우팅 |
| 발송 결과 | 상위 그룹 ID와 고객 ID 중심 | ID map으로 placement·tracking을 찾은 뒤 최종 shard로 재분배 |
| S3 집계 발송량 | 이미 계산된 count | 여정 unique 경로와 중복 합산하지 않고 숫자 Summary로 반영 |

### 용량 산정을 위해 추가한 가정

다음 값은 아직 운영 로그로 확정되지 않은 설계 가정이다. 실제 분포를 확보하면 이
항목을 교체하고 비용·보관 기간을 다시 계산한다.

| 항목 | 1차 가정 | 확정 방법 |
|---|---:|---|
| 최대일 시간대 피크 | 최대일 초당 평균의 3배 | Kafka 시간대별 ingress 확인 |
| 스트레스 버스트 | 평균일 초당 유입의 10배 | 최대 1분·5분·15분 rate 확인 |
| Kafka flush | 500~1,000ms | Summary 반영 SLA와 part 수 비교 |
| 최대 block | 10,000~50,000행 | 처리량·메모리 부하 시험 |
| 압축 후 행 크기 | 60~150byte | `system.parts`의 실제 `bytes_per_row` 측정 |
| 행동 이벤트 raw TTL | 우선 30일 | 법적·업무 보관 요구와 실제 용량 확인 |
| 최초 이벤트 보관 | 1년 이상 | 조회 기간과 캠페인 종료 보관 정책 확인 |
| Summary 보관 | 장기 | 캠페인 종료 후 S3 archive 정책 확인 |
| 조회 동시성 | 1·5·10 단계 측정 | API 예상 동시 요청 수로 교체 |

### 기준 데이터의 일·월·연 환산

| 항목 | 일 | 30일 | 1년 |
|---|---:|---:|---:|
| Kafka 전체 행동 로그, 평균 | 2억 건 | 60억 건 | 730억 건 |
| Kafka 전체 행동 로그, 최대일 지속 가정 | 4억 건 | 120억 건 | 1,460억 건 |
| 30% 저장 후보, 평균 | 6천만 건 | 18억 건 | 219억 건 |
| 30% 저장 후보, 최대일 지속 가정 | 1.2억 건 | 36억 건 | 438억 건 |
| 일반 5% 행동 이벤트 참고, 평균 | 1천만 건 | 3억 건 | 36.5억 건 |
| 일반 5% 행동 이벤트 참고, 최대일 | 2천만 건 | 6억 건 | 73억 건 |

30%는 디스크와 최대 MV 출력량을 잡기 위한 상한이고, 5%는 평상시 실제 행동 이벤트
규모를 이해하기 위한 참고값이다. 두 비율을 같은 의미로 사용하지 않는다. Kafka
Engine은 결과적으로 저장되지 않는 행도 JSON 파싱하고 조건을 평가하므로 CPU는
평균 일 2억 건과 최대 일 4억 건 전체를 기준으로 한다. 표의 최대일 지속 값은 매일
4억 건이 들어오는 보수적인 용량 상한이며 실제 연간 예측값은 일별 분포로 다시 계산한다.

## 트래픽 가정

Kafka에는 행동 로그 전체가 들어오고, ClickHouse Kafka Engine MV가
`tracking_id` 존재 여부를 판정한다.

```text
Kafka 행동 로그: 평균 일 200,000,000건, 최대 일 400,000,000건
    ↓ 전체 JSON 파싱·조건 평가
tracking_id가 있는 최대 30%만 저장
    ↓
ClickHouse 저장: 평균 일 60,000,000건, 최대 일 120,000,000건
```

저장량은 30%로 줄지만 Kafka 소비와 JSON 파싱 CPU는 최대 4억 건 전체를 기준으로
한다. 일 최대량과 시간대 피크는 다른 축이다. 최대일의 초당 평균에 3배를 적용한 값을
일반 시간대 피크로, 평균일 초당 유입의 10배를 짧은 스트레스 버스트로 사용한다.

| 부하 | 평균일 평균 | 최대일 평균 | 최대일 시간대 피크 3배 | 스트레스 버스트 |
|---|---:|---:|---:|---:|
| Kafka 전체 처리 | 2,315건/초 | 4,630건/초 | 13,889건/초 | 23,148건/초 |
| 저장 대상 30% | 694건/초 | 1,389건/초 | 4,167건/초 | 6,944건/초 |
| shard당 Kafka 처리 | 1,158건/초 | 2,315건/초 | 6,945건/초 | 11,574건/초 |
| shard당 저장 | 347건/초 | 695건/초 | 2,084건/초 | 3,472건/초 |
| 1초 flush의 전체 block | 약 2,300행 | 약 4,600행 | 약 13,900행 | 약 23,000행 |

## Kafka block과 shard 라우팅

Kafka 메시지는 개별 offset을 유지하지만 ClickHouse Kafka Engine은 한 polling 구간의
메시지를 block으로 묶어 MV에 전달한다. 1행씩 INSERT하는 구조가 아니다.

```text
Kafka 개별 메시지 N개
    → consumer poll
    → N행 ClickHouse block
    → 필터 MV 1회
    → Distributed 테이블
    → cityHash64(tracking_id)로 shard 선택
    → ReplicatedMergeTree local 테이블
```

초기 flush 간격은 500~1,000ms, 최대 block은 10,000~50,000행을 후보로 한다.
저부하에서는 flush 시간이 반영 지연의 상한이 되고, 고부하에서는 block이 먼저 차면
즉시 처리된다.

Kafka consumer가 실행된 local 테이블에 그대로 저장하면 rebalance 이후 같은
`tracking_id`가 다른 shard로 갈 수 있다. 필터를 통과한 데이터는 Distributed
테이블의 `cityHash64(tracking_id)`로 최종 라우팅한다. producer message key도
`tracking_id`를 사용하여 같은 키의 partition 순서를 유지한다.

한 block 안에 같은 키가 여러 번 들어올 수 있으므로 최초 입수 MV는 다음 순서를
지켜야 한다.

1. 현재 block 안에서 `(placement_id, tracking_id, event_type)`별 최초 후보를 만든다.
2. 기존 최초 이벤트 테이블에 이미 존재하는 키를 제외한다.
3. 통과한 후보만 최초 이벤트와 Summary 경로에 보낸다.

## 예상 CPU·메모리

다음 값은 AWS 실측값이 아니라 lab Kafka 처리량과 신청 자원을 바탕으로 정한 운영
예상 구간이다. 실제 JSON 크기, Action Rule, ID 매핑 JOIN에 따라 달라진다.

| 부하 | 노드당 예상 CPU | 클러스터 CPU | 판단 |
|---|---:|---:|---|
| 평균일 평균 | 20~35% | 약 3~6 vCPU | 여유 예상 |
| 최대일 평균 | 30~50% | 약 5~8 vCPU | 정상 처리 목표 |
| 최대일 시간대 피크 3배 | 55~75% | 약 9~12 vCPU | 피크 지속 시험 필요 |
| 스트레스 버스트 | 70~90% | 약 11~15 vCPU | 짧은 버스트와 lag 회복 목표 |
| backfill 동시 실행 | 80% 이상 가능 | 포화 가능 | 실시간 경로와 분리 |

노드당 32GiB는 다음처럼 나눈다.

| 용도 | 노드당 계획 |
|---|---:|
| Kubernetes·OS·DaemonSet | 3~4GiB |
| ClickHouse Pod request | 24GiB |
| ClickHouse memory limit | 28GiB |
| 평균 적재 예상 | 8~14GiB |
| 적재 + Summary 조회 예상 | 12~18GiB |
| 스트레스 피크 예상 | 16~24GiB |
| 비상 여유 | 최소 4GiB |

무거운 exact 조회와 backfill은 쿼리별 메모리 상한과 동시 실행 수를 별도 제한한다.
Summary 조회의 작은 메모리 사용량만 보고 batch 쿼리까지 무제한으로 허용하지 않는다.

## 저장공간

물리 PVC는 500GiB × 4 = 2TiB지만 replica를 제외한 고유 primary 공간은
2 shard × 500GiB = 1TiB다. 운영 안전선을 70%로 두면 약 700GiB까지 사용한다.

lab 합성 데이터의 압축 크기는 행당 약 13~24byte였지만 반복되는 식별자와 값이 많아
운영 데이터보다 압축에 유리하다. 운영 계획에는 행당 60~150byte 범위를 사용한다.

평균일 기준은 다음과 같다.

| 압축 후 행 크기 | 평균 일 6천만 건 | 30일 primary | replica 포함 물리량 |
|---:|---:|---:|---:|
| 60byte | 약 3.6GB | 약 108GB | 약 216GB |
| 100byte | 약 6GB | 약 180GB | 약 360GB |
| 150byte | 약 9GB | 약 270GB | 약 540GB |

최대 일 4억 건이 30일 내내 지속되는 보수적인 조건은 다음과 같다.

| 압축 후 행 크기 | 최대 일 저장 1.2억 건 | 30일 primary | replica 포함 물리량 |
|---:|---:|---:|---:|
| 60byte | 약 7.2GB | 약 216GB | 약 432GB |
| 100byte | 약 12GB | 약 360GB | 약 720GB |
| 150byte | 약 18GB | 약 540GB | 약 1.08TB |

이벤트 raw와 최초 이벤트 테이블에 같은 넓은 payload를 모두 저장하면 저장량이 거의
두 배가 될 수 있다. 최초 이벤트 테이블에는 Summary와 상세 조회에 필요한 컬럼만
둔다. 평균일 기준 30일 보관은 현재 용량에서 가능성이 높다. 최대일이 한 달 동안
지속되고 행당 150byte이면 한 계층만으로도 primary 안전 사용량 700GiB에 가까워진다.
raw와 최초 이벤트를 넓게 중복 저장하면 용량을 넘을 수 있으므로 실제
`bytes_per_row`, 최대일 발생 일수와 계층 간 중복률을 확인해 TTL을 확정한다.

```sql
SELECT
    table,
    sum(rows) AS rows,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    round(sum(data_compressed_bytes) / sum(rows), 2) AS bytes_per_row
FROM system.parts
WHERE active
  AND database = 'database_name'
GROUP BY table
ORDER BY table;
```

일반 적재의 순수 데이터 대역폭은 gp3 기본 처리량보다 훨씬 작다. 디스크 부하는
backfill, `OPTIMIZE FINAL`, 밀린 background merge, 원본 exact 조회와 replica
재구축에서 커진다. 처음에는 gp3 기본 성능으로 시작하고 merge queue가 지속 증가할
때 IOPS와 처리량을 높인다.

## 월 비용 예상

| 항목 | 구성 | 월 예상 |
|---|---|---:|
| ClickHouse EC2 | `r7i.xlarge` 4대 | 약 $931 |
| ClickHouse 데이터 EBS | gp3 500GiB × 4 | 약 $182 |
| 노드 root EBS | gp3 100GiB × 4 | 약 $36 |
| Keeper PVC | gp3 20GiB × 3 | 약 $5 |
| EKS control plane | 표준 지원 1개 | 약 $73 |
| 소계 | Keeper compute·통신 제외 | 약 $1,227 |
| 원화 환산 | 1달러당 1,400원 | 약 172만 원 |
| 부가세 포함 | 10% 가정 | 약 189만 원 |

Keeper를 기존 시스템 노드에 배치하면 네트워크·snapshot을 포함해 약
200만~220만 원을 1차 예산으로 잡는다. Keeper 전용 노드가 필요하면 그 compute
비용을 추가한다. AZ-C ClickHouse 노드 그룹은 `desired=0`인 동안 EC2 비용이 없지만,
미리 생성한 EBS와 snapshot은 저장 비용이 발생한다.

가격 참고:

- [Amazon EC2 R7i 사양](https://aws.amazon.com/ec2/instance-types/memory-optimized/)
- [Amazon EBS 가격](https://aws.amazon.com/ebs/pricing/)
- [Amazon EKS 가격](https://aws.amazon.com/eks/pricing/)
- [EKS Stateful workload의 AZ별 node group 안내](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)

## lab 실측 근거

lab은 3 shard × 3 replica, Keeper, Redpanda, 모니터링이 Colima의 6 vCPU·16GB를
공유한 환경이다. AWS 예상치는 이 수치를 선형 환산한 확정값이 아니다.

| 실험 | 실측 결과 | 판단에 사용한 의미 |
|---|---|---|
| Kafka Engine 단순 소비 | 약 12.2k~12.7k건/초 | 평균 2.3k건/초보다 높지만 전체 운영 MV는 더 복잡함 |
| 공통 원본 적재 | 2,220만 행, 178.30초 | 합성 SQL 적재라 Kafka 처리량으로 직접 해석하지 않음 |
| A7 backfill + 누적 Summary | 2,220만 행, 124.14초 | 일괄 경로의 실행 가능성 확인 |
| A7 누적 Summary, 집중 상품 | p50 10~15ms, p95 21~56ms | 숫자 Summary는 1초 목표에 여유 |
| A7 시간 Summary, 집중 상품 | p50 13ms, p95 30ms | 시간 Summary 구조의 조회 이점 확인 |
| 집중 상품 직접 `FINAL` | p50 858ms, p95 3.551초 | 서비스 기본 조회에서 제외 |
| 1억 미병합 후보 `FINAL` | 약 4~20초 | merge backlog가 있으면 1초 목표 실패 |
| 1억 조건 Direct/Delta 조회 | p95 21~46ms | 정렬 키로 단일 tracking 범위를 제한하면 빠름 |
| A4 dedup backfill 메모리 | shard당 3.45~3.55GiB | 단일 batch는 24GiB Pod 안에 수용 가능 |
| 집중 상품 원본 시간 집계 | 73.234초 | 원본 재집계는 API 경로에 부적합 |

상세 근거:

- [Kafka Engine 소비 실험](../../../KAFKA-INTEGRATION.md#측정-결과)
- [공통 2,220만 행 기준](../cluster/common/README.md#실행-결과)
- [A7 누적 Summary 결과](../cluster/a7-event-replacing_summary-count/README.md#실행-결과)
- [A7 시간 Summary 결과](../cluster/a7-event-replacing_summary-count/README.md#실행-결과-1)
- [1억 행 Direct·Delta·Replacing 비교](../cluster/a7-event-replacing_summary-count/hybrid-policy-summary/README.md#1억-원본tracking당-100행-비교)
- [A4 backfill·조회 결과](../cluster/a4-dedup-count/README.md#backfill과-저장-공간)
- [A3 원본 직접 조회 결과](../cluster/a3-event-count/README.md#성능)

## 운영 합격 기준

| 검증 항목 | 1차 합격 기준 |
|---|---:|
| 평균일 평균 CPU | 노드별 40% 이하 |
| 최대일 평균 CPU | 노드별 55% 이하 |
| 최대일 시간대 피크 CPU | 노드별 75% 이하 |
| 스트레스 버스트 CPU | 노드별 90% 이하, 종료 후 정상 구간으로 회복 |
| ClickHouse Pod 메모리 | 26GiB 이하 |
| Kafka consumer lag | 피크 종료 후 지속 감소 |
| replication queue | 지속 증가하지 않음 |
| replica delay | 평상시 30초 이하 |
| active part | 시간에 따라 계속 증가하지 않고 안정화 |
| 누적·시간 Summary 조회 | p95 500ms 이하 |
| Summary 반영 지연 | p95 2초 이하 |
| 디스크 사용률 | 70% 이하 |
| AZ 장애 중 조회 | 생존 replica에서 정상 응답 |
| Cold AZ 복구 | 합의한 RTO 안에 노드 기동·replica 재구축 |

## AWS 최종 검증 순서

1. 실제와 같은 JSON 크기와 Action Rule로 평균일 2,315건/초를 30분 이상 입력한다.
2. 최대일 평균 4,630건/초를 30분 이상 유지한다.
3. 최대일 시간대 피크 13,889건/초를 30분 이상 유지한다.
4. 스트레스 버스트 23,148건/초를 15분 이상 입력하고 Kafka lag 회복 시간을 잰다.
5. 각 단계에서 Summary 조회를 동시성 1·5·10으로 실행한다.
6. 적재만 실행한 상태와 background merge·조회가 겹친 상태를 나눠 측정한다.
7. 한 AZ의 ClickHouse 노드를 중단하고 조회·적재와 Keeper quorum을 확인한다.
8. AZ-C node group을 0대에서 2대로 확장하고 replica 복구 시간을 기록한다.
9. 7일 이상 실제 분포를 적재한 뒤 `bytes_per_row`와 예상 보관 기간을 다시 계산한다.

이 검증을 통과하면 `2 shard × 2 replica`, `r7i.xlarge` 4대, gp3 500GiB × 4를
운영 시작 사양으로 확정한다. 스트레스 버스트 이후 consumer lag가 회복되지 않거나
최대일 시간대 피크에서 CPU가 75%를 계속 넘으면 consumer·partition 배치와 MV 비용을 먼저 확인한 뒤
`r7i.2xlarge`로 수직 확장한다.
