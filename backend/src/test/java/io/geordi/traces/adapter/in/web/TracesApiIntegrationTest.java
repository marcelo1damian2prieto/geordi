package io.geordi.traces.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.traces.application.TraceQueryService;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.util.List;
import java.util.Optional;
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
        classes = {GeordiApplication.class, TracesApiIntegrationTest.StubConfiguration.class},
        properties = "geordi.modules.metrics.enabled=false",
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class TracesApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void acceptsIsoUtcInstantsThroughTheRealSpringMvcConversionLayer() {
        var response = restTemplate.getForEntity(
                "http://localhost:" + port + "/api/traces/services?from={from}&to={to}",
                String.class,
                "2026-08-13T11:45:00Z",
                "2026-08-13T12:00:00Z");

        assertThat(response.getStatusCode()).as(response.getBody()).isEqualTo(HttpStatus.OK);
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class StubConfiguration {

        @Bean
        @Primary
        TraceQueryService stubTraceQueryService() {
            return new TraceQueryService(new TraceQueryPort() {
                @Override
                public List<ServiceIdentity> findServices(TimeRange range) {
                    return List.of();
                }

                @Override
                public List<TraceSummary> search(TraceSearchCriteria criteria) {
                    return List.of();
                }

                @Override
                public Optional<TraceDetail> findTrace(TraceId traceId) {
                    return Optional.empty();
                }
            });
        }
    }
}
