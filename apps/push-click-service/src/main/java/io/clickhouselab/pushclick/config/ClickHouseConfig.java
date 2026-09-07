package io.clickhouselab.pushclick.config;

import com.zaxxer.hikari.HikariDataSource;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

import javax.sql.DataSource;

/**
 * ClickHouse 연결 설정.
 *
 * <p>{@code async_insert=1&wait_for_async_insert=1}을 JDBC URL에 명시해, 이
 * 서비스가 매 요청마다 단건 INSERT를 날려도 서버가 여러 소스의 소량 INSERT를
 * 모아 하나의 파트로 합쳐주도록 한다. 이렇게 하지 않으면 파티션당 파트 수가
 * 빠르게 늘어 {@code parts_to_delay_insert}(1000)/{@code parts_to_throw_insert}
 * (3000) 임계값에 부딪혀 INSERT가 지연/거부될 수 있다 (PRODUCTION.md 4절 참고).
 *
 * <p>처리량이 이 방식으로 부족해지면, 애플리케이션 레벨에서 이벤트를 버퍼에
 * 모았다가 주기적으로 배치 INSERT하는 방식으로 전환하는 것이 다음 단계다
 * (README.md "확장 아이디어" 참고).
 */
@Configuration
public class ClickHouseConfig {

    @Bean
    public DataSource dataSource(
            @Value("${clickhouse.jdbc-url}") String jdbcUrl,
            @Value("${clickhouse.username}") String username,
            @Value("${clickhouse.password}") String password
    ) {
        HikariDataSource dataSource = DataSourceBuilder.create()
                .driverClassName("com.clickhouse.jdbc.ClickHouseDriver")
                .url(jdbcUrl)
                .username(username)
                .password(password)
                .type(HikariDataSource.class)
                .build();
        dataSource.setPoolName("clickhouse-pool");
        dataSource.setMaximumPoolSize(10);
        return dataSource;
    }

    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}
