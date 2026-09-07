package io.clickhouselab.pushclick.domain;

import java.time.LocalDateTime;
import java.util.UUID;

/**
 * 클릭 이벤트에는 {@code campaignId}를 발송 이벤트와 별개로 직접 태깅한다.
 *
 * <p>ClickHouse Materialized View는 원본 테이블 한쪽에 INSERT될 때만 트리거되는
 * "per-source-table" 방식이라, 발송과 클릭을 실시간으로 JOIN하는 단일 MV를
 * 만들 수 없다(클릭이 나중에 도착해도 발송 쪽 MV가 재계산되지 않아 결과가
 * 틀어진다). 그래서 클릭 이벤트 자체에 campaignId를 실어 보내, 발송/클릭을
 * 각각 독립적으로 집계할 수 있게 한다. 자세한 설명은 서비스 README와
 * {@code schema/001_init.sql}의 주석 참고.
 */
public record ClickEvent(
        UUID clickId,
        UUID sendId,
        long customerId,
        long campaignId,
        LocalDateTime clickedAt
) {
}
