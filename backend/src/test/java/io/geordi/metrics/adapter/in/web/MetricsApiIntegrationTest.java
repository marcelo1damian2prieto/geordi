package io.geordi.metrics.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.application.MetricsQueryService;
import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpStatus;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;

@SpringBootTest(
        classes = {GeordiApplication.class, MetricsApiIntegrationTest.StubMetricsConfiguration.class},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class MetricsApiIntegrationTest {

    private static final String FROM = "2026-08-13T18:09:59Z";
    private static final String TO = "2026-08-13T18:24:59Z";

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void acceptsIsoUtcInstantsThroughTheRealSpringMvcConversionLayer() {
        var response = restTemplate.getForEntity(
                "http://localhost:" + port + "/api/metrics/services?from={from}&to={to}",
                String.class,
                FROM,
                TO);

        assertThat(response.getStatusCode()).as(response.getBody()).isEqualTo(HttpStatus.OK);
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class StubMetricsConfiguration {

        @Bean
        @Primary
        MetricsQueryService stubMetricsQueryService() {
            return new MetricsQueryService(new MetricsQueryPort() {
                @Override
                public List<ServiceIdentity> findServices(TimeRange range) {
                    return List.of();
                }

                @Override
                public List<MetricSeries> query(MetricsQuery query) {
                    return List.of();
                }
            });
        }
    }
}
