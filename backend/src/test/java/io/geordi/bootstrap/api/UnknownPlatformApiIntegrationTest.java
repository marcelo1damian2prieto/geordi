package io.geordi.bootstrap.api;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

@SpringBootTest(
        classes = {GeordiApplication.class, UnknownPlatformApiIntegrationTest.UnknownModuleConfiguration.class},
        properties = {"geordi.modules.metrics.enabled=false", "geordi.modules.traces.enabled=false",
            "geordi.modules.logs.enabled=false", "geordi.modules.service-map.enabled=false",
            "geordi.modules.slos.enabled=false"},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UnknownPlatformApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void keepsUnknownProductHealthAtHttp200ButMarksReadinessDown() {
        ResponseEntity<Map<String, Object>> productHealth = getJson("/api/platform/health");
        ResponseEntity<Map<String, Object>> readiness = getJson("/actuator/health/readiness");

        assertThat(productHealth.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(productHealth.getBody()).containsEntry("status", "UNKNOWN");
        assertThat(readiness.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
        assertThat(readiness.getBody()).containsEntry("status", "DOWN");
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(
                "http://localhost:" + port + path,
                HttpMethod.GET,
                null,
                new ParameterizedTypeReference<>() {
                });
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class UnknownModuleConfiguration {

        @Bean
        PlatformModule unknownTestModule() {
            return new PlatformModule() {
                @Override
                public String id() {
                    return "unknown-test-module";
                }

                @Override
                public String name() {
                    return "Unknown Test Module";
                }

                @Override
                public ModuleHealthCheck healthCheck() {
                    return () -> ModuleStatus.UNKNOWN;
                }
            };
        }
    }
}
