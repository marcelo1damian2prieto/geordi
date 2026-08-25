package io.geordi.bootstrap.api;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.ResponseEntity;

@SpringBootTest(
        classes = {GeordiApplication.class, ModuleInventoryIsolationIntegrationTest.CountingModuleConfiguration.class},
        properties = {"geordi.modules.metrics.enabled=false", "geordi.modules.traces.enabled=false",
            "geordi.modules.service-map.enabled=false", "geordi.modules.alerts.enabled=false"},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class ModuleInventoryIsolationIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Autowired
    private AtomicInteger countingModuleChecks;

    @Test
    @SuppressWarnings("unchecked")
    void inventoryDoesNotEvaluateHealthAndHealthEvaluatesOnce() {
        ResponseEntity<Map<String, Object>> inventoryResponse = getJson("/api/modules");

        assertThat(countingModuleChecks).hasValue(0);
        List<Map<String, Object>> modules =
                (List<Map<String, Object>>) inventoryResponse.getBody().get("modules");
        assertThat(modules).filteredOn(module -> module.get("id").equals("counting-module"))
                .singleElement()
                .satisfies(module -> assertThat(module).containsOnlyKeys("id", "name", "enabled"));

        getJson("/api/platform/health");
        assertThat(countingModuleChecks).hasValue(1);
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
    static class CountingModuleConfiguration {

        @Bean
        AtomicInteger countingModuleChecks() {
            return new AtomicInteger();
        }

        @Bean
        PlatformModule countingPlatformModule(AtomicInteger countingModuleChecks) {
            return new PlatformModule() {
                @Override
                public String id() {
                    return "counting-module";
                }

                @Override
                public String name() {
                    return "Counting Module";
                }

                @Override
                public ModuleHealthCheck healthCheck() {
                    return () -> {
                        countingModuleChecks.incrementAndGet();
                        return ModuleStatus.UP;
                    };
                }
            };
        }
    }
}
