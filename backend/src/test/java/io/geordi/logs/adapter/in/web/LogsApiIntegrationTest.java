package io.geordi.logs.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsQueryService;
import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.http.HttpStatus;

@SpringBootTest(
        classes = {GeordiApplication.class, LogsApiIntegrationTest.StubConfiguration.class},
        properties = {"geordi.modules.metrics.enabled=false", "geordi.modules.traces.enabled=false"},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class LogsApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void acceptsIsoUtcInstantsThroughTheRealSpringMvcConversionLayer() {
        var response = restTemplate.getForEntity(
                "http://localhost:" + port + "/api/logs/services?from={from}&to={to}",
                String.class,
                "2026-08-14T11:45:00Z",
                "2026-08-14T12:00:00Z");

        assertThat(response.getStatusCode()).as(response.getBody()).isEqualTo(HttpStatus.OK);
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class StubConfiguration {

        @Bean
        @Primary
        LogsQueryService stubLogsQueryService() {
            return new LogsQueryService(new LogsQueryPort() {
                @Override
                public List<ServiceIdentity> findServices(TimeRange range) {
                    return List.of();
                }

                @Override
                public List<LogRecord> search(LogSearchCriteria criteria) {
                    return List.of();
                }
            });
        }
    }
}
