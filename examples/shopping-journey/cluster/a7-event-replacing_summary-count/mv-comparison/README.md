# Cart delta MV 비교

카트 이벤트의 현재 INSERT block과 기존 전체 이력을 비교해 시간 delta를 만드는 두 MV를 비교한다.

| 파일 | 이력 조회 방식 | 100만 행 실험 결과 |
|---|---|---|
| `cart-delta-full-history-join.sql` | 후보를 전체 이력과 바로 JOIN | INSERT마다 약 100만 행 조회 |
| `cart-delta-candidate-filter.sql` | 후보 키로 이력을 먼저 제한한 뒤 JOIN | INSERT마다 약 8천 행 조회 |

쇼핑몰 예제의 키는 실제 모델의 다음 항목에 대응한다.

| 쇼핑몰 예제 | 실제 모델 |
|---|---|
| `product_id` | `placement_id` |
| `journey_id` | `tracking_id` |

두 파일은 다음 객체가 존재한다고 가정한다.

```text
shop_a7_direct.cart_events_local
shop_a7_direct.cart_events_history_local
shop_a7_direct.event_summary_delta_local
```

`cart_events_local`에는 현재 INSERT block과 이전 행을 구분하기 위한 `ingest_row_id UUID`가 있어야 한다. `cart_events_history_local`은 다음과 같이 전체 저장 이력을 읽는 일반 View다.

```sql
CREATE VIEW shop_a7_direct.cart_events_history_local AS
SELECT *
FROM shop_a7_direct.cart_events_local;
```

두 MV는 같은 입력에서 같은 delta를 생성하므로 **동시에 활성화하지 않는다**. 성능 비교 시 한 MV를 DROP한 다음 다른 MV를 생성한다.

두 쿼리 모두 다음 판정 규칙을 사용한다.

| 조건 | 생성 delta |
|---|---|
| 기존 이력 없음 | 신규 시간 `+1` |
| 신규 시간이 기존 최소보다 빠름 | 기존 시간 `-1`, 신규 시간 `+1` |
| 신규 시간이 같거나 늦음 | 행을 생성하지 않음 |
