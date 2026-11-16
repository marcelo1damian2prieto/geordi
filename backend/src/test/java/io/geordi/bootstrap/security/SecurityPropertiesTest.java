package io.geordi.bootstrap.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class SecurityPropertiesTest {
    @TempDir
    Path directory;

    @Test
    void validatesOnlyExplicitHttpsOriginsAudienceSeparationAndPermissionNames() throws Exception {
        Path secret = directory.resolve("client-secret");
        Files.writeString(secret, "private-test-sentinel");
        var valid = configuration("https://geordi.localhost", "geordi-api", secret, List.of("observability:read"));
        assertThat(valid.toString()).doesNotContain("private-test-sentinel");
        assertThatThrownBy(() -> configuration("http://geordi.localhost", "geordi-api", secret, List.of()))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> configuration("https://geordi.localhost/path", "geordi-api", secret, List.of()))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> configuration("https://geordi.localhost", "geordi-browser", secret, List.of()))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> configuration("https://geordi.localhost", "geordi-api", secret, List.of("ADMIN")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> configuration("https://geordi.localhost", "geordi-api", directory.resolve("absent"), List.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static SecurityProperties configuration(String origin, String audience, Path secret, List<String> grants) {
        return new SecurityProperties("https://auth.localhost", audience, "geordi-browser", secret,
                origin, "geordi_grants", Map.of("viewer", grants));
    }
}
