package io.clickhouselab.pushclick;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

/**
 * 스프링 컨텍스트 로드만 확인한다. ClickHouseConfig가 DataSource 빈을 만드는
 * 시점에 실제 커넥션을 맺으려 시도하므로, 이 테스트는 로컬에 port-forward된
 * ClickHouse가 떠 있을 때만 통과한다 (Quickstart 참고).
 */
@SpringBootTest
class PushClickServiceApplicationTests {

    @Test
    void contextLoads() {
    }
}
