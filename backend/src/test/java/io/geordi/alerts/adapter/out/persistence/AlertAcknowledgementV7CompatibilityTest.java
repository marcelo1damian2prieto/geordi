package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.domain.AlertEpisodeId;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

class AlertAcknowledgementV7CompatibilityTest {
    private static final String FIXTURES = "io/geordi/alerts/adapter/out/persistence/compatibility/";

    @Test
    void originalInsertAndReadPreserveLegacyUnicodeNullReasonAndNanoseconds() throws Exception {
        var source = new DriverManagerDataSource("jdbc:h2:mem:ack-v7-compatibility;DB_CLOSE_DELAY=-1", "sa", "");
        Flyway.configure().dataSource(source).locations("classpath:db/migration").load().migrate();
        var populator = new ResourceDatabasePopulator(new ClassPathResource(FIXTURES + "ack-v7.sql"));
        populator.setSqlScriptEncoding(StandardCharsets.UTF_8.name());
        populator.execute(source);
        var mapper = JsonMapper.builder().findAndAddModules().build();
        var repository = new H2AlertLifecycleRepository(new JdbcTemplate(source), mapper,
                new TransactionTemplate(new JdbcTransactionManager(source)));
        try (var stream = new ClassPathResource(FIXTURES + "ack-v7-api.json").getInputStream()) {
            var expected = mapper.readTree(stream);
            for (int index = 0; index < 2; index++) {
                var actual = repository.findByEpisodeId(new AlertEpisodeId((index == 0 ? "a" : "b").repeat(64)))
                        .orElseThrow();
                var row = expected.get(index);
                assertThat(actual.actor()).isEqualTo(row.get("actor").asText());
                assertThat(actual.reason()).isEqualTo(row.get("reason").isNull() ? null : row.get("reason").asText());
                assertThat(actual.acknowledgedAt()).isEqualTo(Instant.parse(row.get("acknowledgedAt").asText()));
            }
        }
    }
}
