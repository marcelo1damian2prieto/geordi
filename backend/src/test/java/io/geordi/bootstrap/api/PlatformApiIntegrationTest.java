package io.geordi.bootstrap.api;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpStatus;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.ResponseEntity;

@SpringBootTest(
        classes = GeordiApplication.class,
        properties = "geordi.modules.metrics.enabled=false",
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class PlatformApiIntegrationTest {

    @LocalServerPort
    private int port;

    @Autowired
    private TestRestTemplate restTemplate;

    @Autowired
    private BuildProperties buildProperties;

    @Test
    void exposesTheExactPlatformIdentity() {
        ResponseEntity<Map<String, Object>> response = restTemplate.exchange(
                url("/api/platform"),
                org.springframework.http.HttpMethod.GET,
                null,
                new ParameterizedTypeReference<>() {
                });

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsExactlyInAnyOrderEntriesOf(Map.of(
                "id", "geordi",
                "name", "Geordi",
                "version", buildProperties.getVersion()));
    }

    @Test
    @SuppressWarnings("unchecked")
    void exposesRegisteredModulesAndAggregatedHealth() {
        ResponseEntity<Map<String, Object>> modulesResponse = getJson("/api/modules");
        ResponseEntity<Map<String, Object>> healthResponse = getJson("/api/platform/health");

        assertThat(modulesResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        List<Map<String, Object>> modules = (List<Map<String, Object>>) modulesResponse.getBody().get("modules");
        assertThat(modules).extracting(module -> module.get("id"))
                .containsExactly("core", "metrics", "self-observability");
        assertThat(modules).allSatisfy(module -> {
            assertThat(module).containsOnlyKeys("id", "name", "enabled");
        });
        assertThat(modules).filteredOn(module -> module.get("id").equals("metrics"))
                .singleElement().satisfies(module -> assertThat(module).containsEntry("enabled", false));

        assertThat(healthResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(healthResponse.getBody().get("status")).isEqualTo("UP");
        List<Map<String, Object>> healthModules =
                (List<Map<String, Object>>) healthResponse.getBody().get("modules");
        assertThat(healthModules).filteredOn(module -> module.get("id").equals("metrics"))
                .singleElement().satisfies(module -> assertThat(module).containsEntry("status", "DISABLED"));
    }

    @Test
    void exposesActuatorLivenessAndReadiness() {
        assertThat(getJson("/actuator/health/liveness").getStatusCode())
                .isEqualTo(HttpStatus.OK);
        assertThat(getJson("/actuator/health/readiness").getStatusCode())
                .isEqualTo(HttpStatus.OK);
    }

    private ResponseEntity<Map<String, Object>> getJson(String path) {
        return restTemplate.exchange(
                url(path),
                org.springframework.http.HttpMethod.GET,
                null,
                new ParameterizedTypeReference<>() {
                });
    }

    private String url(String path) {
        return "http://localhost:" + port + path;
    }
}
