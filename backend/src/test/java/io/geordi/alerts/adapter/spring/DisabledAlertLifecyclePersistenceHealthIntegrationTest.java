package io.geordi.alerts.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.alerts.application.port.out.AlertLifecyclePersistenceHealthProbe;
import io.geordi.bootstrap.GeordiApplication;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

@SpringBootTest(
        classes = {GeordiApplication.class, DisabledAlertLifecyclePersistenceHealthIntegrationTest.TestConfig.class},
        properties = {
            "geordi.modules.metrics.enabled=false",
            "geordi.modules.traces.enabled=false",
            "geordi.modules.logs.enabled=false",
            "geordi.modules.service-map.enabled=false",
            "geordi.modules.slos.enabled=false",
            "geordi.modules.alerts.enabled=false"
        },
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class DisabledAlertLifecyclePersistenceHealthIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void ignoresUnavailableLifecyclePersistenceWhenAlertsAreDisabled() {
        assertThat(getJson("/api/platform/health").getBody()).containsEntry("status", "UP");
        assertThat(getJson("/actuator/health/readiness").getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(restTemplate.getForEntity(url("/api/alert-states"), String.class).getStatusCode())
                .isEqualTo(HttpStatus.NOT_FOUND);
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(
                url(path), HttpMethod.GET, null, new ParameterizedTypeReference<>() { });
    }

    private String url(String path) {
        return "http://localhost:" + port + path;
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class TestConfig {

        @Bean
        @Primary
        AlertLifecyclePersistenceHealthProbe unavailableLifecyclePersistence() {
            return () -> false;
        }
    }
}
