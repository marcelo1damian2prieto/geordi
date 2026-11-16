package io.geordi.bootstrap.security.metadata;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.bootstrap.security.SecurityFailure;
import java.net.URI;
import java.util.HashSet;
import java.util.Set;
import java.util.function.Function;

/** Discovers only from the configured issuer and verifies the returned origin metadata. */
public final class OidcMetadataClient {
    private static final int MAX_DISCOVERY_BYTES = 64 * 1024;
    private final String configuredIssuer;
    private final Function<URI, JsonNode> discoveryRequest;

    public OidcMetadataClient(String configuredIssuer, BoundedHttpsJsonClient transport) {
        this(configuredIssuer, uri -> transport.get(uri, MAX_DISCOVERY_BYTES));
    }

    OidcMetadataClient(String configuredIssuer, Function<URI, JsonNode> discoveryRequest) {
        this.configuredIssuer = configuredIssuer;
        this.discoveryRequest = discoveryRequest;
    }

    public TrustedIssuerMetadata discover() {
        try {
            String suffix = configuredIssuer.endsWith("/") ? ".well-known/openid-configuration"
                    : "/.well-known/openid-configuration";
            URI discovery = URI.create(configuredIssuer + suffix);
            JsonNode document = discoveryRequest.apply(discovery);
            if (document == null || !document.isObject() || !configuredIssuer.equals(text(document, "issuer"))) {
                throw SecurityFailure.invalid();
            }
            URI authorization = https(text(document, "authorization_endpoint"));
            URI token = https(text(document, "token_endpoint"));
            URI jwks = https(text(document, "jwks_uri"));
            requireContains(document.get("response_types_supported"), "code");
            requireContains(document.get("code_challenge_methods_supported"), "S256");
            requireContains(document.get("token_endpoint_auth_methods_supported"), "client_secret_basic");
            return new TrustedIssuerMetadata(configuredIssuer, authorization, token, jwks);
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            throw SecurityFailure.invalid();
        }
    }

    private static URI https(String value) {
        URI uri = URI.create(value);
        if (!uri.isAbsolute() || !"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                || uri.getUserInfo() != null || uri.getFragment() != null) throw SecurityFailure.invalid();
        return uri;
    }

    private static String text(JsonNode object, String key) {
        JsonNode value = object.get(key);
        if (value == null || !value.isTextual() || value.textValue().isBlank()) throw SecurityFailure.invalid();
        return value.textValue();
    }

    private static void requireContains(JsonNode values, String expected) {
        if (values == null || !values.isArray()) throw SecurityFailure.invalid();
        Set<String> supported = new HashSet<>();
        for (JsonNode value : values) {
            if (!value.isTextual()) throw SecurityFailure.invalid();
            supported.add(value.textValue());
        }
        if (!supported.contains(expected)) throw SecurityFailure.invalid();
    }
}
