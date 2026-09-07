package io.clickhouselab.pushclick.domain;

import java.time.LocalDateTime;

public record Customer(
        long customerId,
        String deviceToken,
        String segment,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
}
