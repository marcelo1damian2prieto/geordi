package io.geordi.bootstrap.security.metadata;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.bootstrap.security.fixture.GeordiTestOidcFixture;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import org.junit.jupiter.api.Test;

class BoundedHttpsJsonClientTest {
    @Test
    void loadsPrivatePasswordFileTrustStoreAndVerifiesTheConfiguredIssuer() throws Exception {
        GeordiTestOidcFixture issuer = GeordiTestOidcFixture.instance();
        Path passwordFile = Files.createTempFile("geordi-m19-trust-password-", ".txt");
        passwordFile.toFile().deleteOnExit();
        Files.writeString(passwordFile, System.getProperty("javax.net.ssl.trustStorePassword"), StandardCharsets.UTF_8);
        Path trustStore = Path.of(System.getProperty("javax.net.ssl.trustStore"));
        BoundedHttpsJsonClient client = new BoundedHttpsJsonClient(Duration.ofSeconds(2), trustStore, passwordFile);

        assertThat(client.get(URI.create(issuer.issuer() + "/health"), 1024).path("status").asText()).isEqualTo("UP");
    }

    @Test
    void enforcesTotalDeadlineWhenTlsServerStallsAfterResponseHeaders() {
        GeordiTestOidcFixture issuer = GeordiTestOidcFixture.instance();
        BoundedHttpsJsonClient client = new BoundedHttpsJsonClient(Duration.ofMillis(200));
        long started = System.nanoTime();

        assertThatThrownBy(() -> client.get(URI.create(issuer.issuer() + "/slow-body"), 1024))
                .isInstanceOf(SecurityFailure.class)
                .extracting(failure -> ((SecurityFailure) failure).kind())
                .isEqualTo(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);

        assertThat(Duration.ofNanos(System.nanoTime() - started)).isLessThan(Duration.ofSeconds(1));
    }
}
