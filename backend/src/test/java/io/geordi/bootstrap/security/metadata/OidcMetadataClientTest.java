package io.geordi.bootstrap.security.metadata;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import java.net.URI;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

class OidcMetadataClientTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String ISSUER = "https://auth.example/tenant";

    @Test
    void discoversOnlyFromConfiguredIssuerAndRequiresSecureEndpointsAndProtocols() throws Exception {
        AtomicReference<URI> requested = new AtomicReference<>();
        JsonNode fixture = document(ISSUER, "https://auth.example/authorize", "https://auth.example/token",
                "https://auth.example/keys");
        OidcMetadataClient client = new OidcMetadataClient(ISSUER, uri -> {
            requested.set(uri);
            return fixture;
        });

        TrustedIssuerMetadata metadata = client.discover();

        assertThat(requested.get()).isEqualTo(URI.create(ISSUER + "/.well-known/openid-configuration"));
        assertThat(metadata.issuer()).isEqualTo(ISSUER);
        assertThat(metadata.jwksUri()).isEqualTo(URI.create("https://auth.example/keys"));
    }

    @Test
    void rejectsIssuerSubstitutionHttpEndpointsAndMissingPkceOrClientAuthentication() throws Exception {
        assertInvalid(document("https://other.example", "https://auth.example/a", "https://auth.example/t",
                "https://auth.example/j"));
        assertInvalid(document(ISSUER, "http://auth.example/a", "https://auth.example/t", "https://auth.example/j"));

        JsonNode noPkce = JSON.readTree(documentJson(ISSUER, "https://auth.example/a", "https://auth.example/t",
                "https://auth.example/j").replace("\"S256\"", "\"plain\""));
        assertInvalid(noPkce);

        JsonNode noBasic = JSON.readTree(documentJson(ISSUER, "https://auth.example/a", "https://auth.example/t",
                "https://auth.example/j").replace("\"client_secret_basic\"", "\"private_key_jwt\""));
        assertInvalid(noBasic);
    }

    private static JsonNode document(String issuer, String authorization, String token, String jwks) throws Exception {
        return JSON.readTree(documentJson(issuer, authorization, token, jwks));
    }

    private static String documentJson(String issuer, String authorization, String token, String jwks) {
        return "{\"issuer\":\"" + issuer + "\",\"authorization_endpoint\":\"" + authorization
                + "\",\"token_endpoint\":\"" + token + "\",\"jwks_uri\":\"" + jwks
                + "\",\"response_types_supported\":[\"code\"],\"code_challenge_methods_supported\":[\"S256\"],"
                + "\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\"]}";
    }

    private static void assertInvalid(JsonNode document) {
        assertThatThrownBy(() -> new OidcMetadataClient(ISSUER, uri -> document).discover())
                .isInstanceOf(SecurityFailure.class);
    }
}
