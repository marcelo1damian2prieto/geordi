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
        classes = {GeordiApplication.class, DownPlatformApiIntegrationTest.DownModuleConfiguration.class},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class DownPlatformApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void keepsProductHealthAtHttp200WhileReadinessUsesOperationalStatus() {
        ResponseEntity<Map<String, Object>> productHealth = getJson("/api/platform/health");
        ResponseEntity<Map<String, Object>> readiness = getJson("/actuator/health/readiness");

        assertThat(productHealth.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(productHealth.getBody()).containsEntry("status", "DOWN");
        assertThat(readiness.getStatusCode()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
    }

    private String url(String path) {
        return "http://localhost:" + port + path;
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(
                url(path), HttpMethod.GET, null, new ParameterizedTypeReference<>() {
                });
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class DownModuleConfiguration {

        @Bean
        PlatformModule downTestModule() {
            return new PlatformModule() {
                @Override
                public String id() {
                    return "down-test-module";
                }

                @Override
                public String name() {
                    return "Down Test Module";
                }

                @Override
                public ModuleHealthCheck healthCheck() {
                    return () -> ModuleStatus.DOWN;
                }
            };
        }
    }
}
