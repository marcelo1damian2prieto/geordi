package io.geordi.alerts.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.application.port.out.AlertLifecyclePersistenceHealthProbe;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.bootstrap.GeordiApplication;
import io.geordi.metrics.adapter.out.telemetry.ObservedMetricsQueryAdapter;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.BeforeEach;
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
import org.springframework.test.context.bean.override.mockito.MockitoBean;

@SpringBootTest(
        classes = {GeordiApplication.class, AlertLifecyclePersistenceHealthIntegrationTest.TestConfig.class},
        properties = {
            "geordi.modules.traces.enabled=false",
            "geordi.modules.logs.enabled=false",
            "geordi.modules.service-map.enabled=false"
        },
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class AlertLifecyclePersistenceHealthIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Autowired
    private MutableLifecyclePersistence persistence;

    @MockitoBean(name = "observedMetricsQueryAdapter")
    private ObservedMetricsQueryAdapter metricsBackend;

    @BeforeEach
    void keepUnrelatedMetricsHealthUp() {
        when(metricsBackend.isQueryable()).thenReturn(true);
    }

    @Test
    @SuppressWarnings("unchecked")
    void reflectsPersistenceOutageAndRecoveryInPlatformHealthAndReadiness() {
        assertThat(getJson("/api/platform/health").getBody()).containsEntry("status", "UP");
        assertThat(getJson("/actuator/health/readiness").getStatusCode()).isEqualTo(HttpStatus.OK);

        persistence.setAvailable(false);

        ResponseEntity<Map<String, Object>> lifecycle = getJson("/api/alert-states");
        assertThat(lifecycle.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
        assertThat(lifecycle.getBody()).containsEntry("title", "Alert lifecycle unavailable");
        ResponseEntity<Map<String, Object>> platformHealth = getJson("/api/platform/health");
        assertThat(platformHealth.getBody()).containsEntry("status", "DOWN");
        List<Map<String, Object>> modules = (List<Map<String, Object>>) platformHealth.getBody().get("modules");
        assertThat(modules).filteredOn(module -> module.get("id").equals("alerts"))
                .singleElement().satisfies(module -> assertThat(module).containsEntry("status", "DOWN"));
        ResponseEntity<Map<String, Object>> readiness = getJson("/actuator/health/readiness");
        assertThat(readiness.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
        assertThat(readiness.getBody()).containsEntry("status", "DOWN");

        persistence.setAvailable(true);

        assertThat(getJson("/api/alert-states").getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(getJson("/api/platform/health").getBody()).containsEntry("status", "UP");
        assertThat(getJson("/actuator/health/readiness").getStatusCode()).isEqualTo(HttpStatus.OK);
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(
                "http://localhost:" + port + path,
                HttpMethod.GET,
                null,
                new ParameterizedTypeReference<>() { });
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class TestConfig {

        @Bean
        @Primary
        MutableLifecyclePersistence mutableLifecyclePersistence() {
            return new MutableLifecyclePersistence();
        }
    }

    static final class MutableLifecyclePersistence
            implements AlertLifecycleRepository, AlertLifecyclePersistenceHealthProbe {

        private final AtomicBoolean available = new AtomicBoolean(true);

        void setAvailable(boolean value) {
            available.set(value);
        }

        @Override
        public boolean isAvailable() {
            return available.get();
        }

        @Override
        public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
            requireAvailable();
            return Optional.empty();
        }

        @Override
        public List<VersionedAlertLifecycle> findAll() {
            requireAvailable();
            return List.of();
        }

        @Override
        public boolean insertIfAbsent(AlertLifecycle lifecycle) {
            requireAvailable();
            return true;
        }

        @Override
        public boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion) {
            requireAvailable();
            return true;
        }

        private void requireAvailable() {
            if (!available.get()) {
                throw new AlertLifecyclePersistenceException(
                        "test lifecycle persistence unavailable", new IllegalStateException("unavailable"));
            }
        }
    }
}
