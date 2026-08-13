package io.geordi.traces.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

@SpringBootTest(
        classes = GeordiApplication.class,
        properties = {"geordi.modules.traces.enabled=false", "geordi.modules.metrics.enabled=false"},
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class TracesModuleIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    @SuppressWarnings("unchecked")
    void disabledModuleRemainsInInventorySkipsHealthAndHasNoRoutes() {
        ResponseEntity<Map<String, Object>> inventory = getJson("/api/modules");
        List<Map<String, Object>> modules = (List<Map<String, Object>>) inventory.getBody().get("modules");
        assertThat(modules).filteredOn(item -> item.get("id").equals("traces"))
                .singleElement().satisfies(item -> assertThat(item).containsEntry("enabled", false));

        ResponseEntity<Map<String, Object>> health = getJson("/api/platform/health");
        List<Map<String, Object>> healthModules = (List<Map<String, Object>>) health.getBody().get("modules");
        assertThat(healthModules).filteredOn(item -> item.get("id").equals("traces"))
                .singleElement().satisfies(item -> assertThat(item).containsEntry("status", "DISABLED"));

        assertThat(restTemplate.getForEntity(url("/api/traces/services"), String.class).getStatusCode())
                .isEqualTo(HttpStatus.NOT_FOUND);
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(url(path), HttpMethod.GET, null, new ParameterizedTypeReference<>() { });
    }

    private String url(String path) {
        return "http://localhost:" + port + path;
    }
}
