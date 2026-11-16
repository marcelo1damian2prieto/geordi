package io.geordi.bootstrap.security.oidc;

import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.bootstrap.security.SecurityProperties;
import io.geordi.bootstrap.security.metadata.BoundedHttpsJsonClient;
import io.geordi.bootstrap.security.metadata.TrustedIssuerMetadata;
import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Map;

/** One-shot code exchange; only the ID token string leaves this adapter. */
public final class OidcAuthorizationCodeTokenClient implements AuthorizationCodeTokenExchange {
    private static final int MAX_RESPONSE_BYTES = 64 * 1024;
    private final BoundedHttpsJsonClient transport;
    private final TrustedIssuerMetadata metadata;
    private final SecurityProperties properties;

    public OidcAuthorizationCodeTokenClient(BoundedHttpsJsonClient transport,
            TrustedIssuerMetadata metadata, SecurityProperties properties) {
        this.transport = transport;
        this.metadata = metadata;
        this.properties = properties;
    }

    @Override
    public String exchange(String code, String codeVerifier, URI redirectUri) {
        if (code == null || code.isBlank() || code.length() > 2048 || !printable(code)
                || codeVerifier == null || !codeVerifier.matches("[A-Za-z0-9._~-]{43,128}")
                || redirectUri == null || !"https".equalsIgnoreCase(redirectUri.getScheme())) {
            throw SecurityFailure.invalid();
        }
        Map<String, String> form = new LinkedHashMap<>();
        form.put("grant_type", "authorization_code");
        form.put("code", code);
        form.put("redirect_uri", redirectUri.toASCIIString());
        form.put("code_verifier", codeVerifier);
        String secret;
        try {
            secret = properties.clientSecret();
        } catch (RuntimeException failure) {
            throw new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
        }
        var response = transport.postForm(metadata.tokenEndpoint(), MAX_RESPONSE_BYTES, form,
                properties.browserClientId(), secret);
        if (response == null || !response.isObject()) throw new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
        var idToken = response.get("id_token");
        if (idToken == null || !idToken.isTextual() || idToken.textValue().isBlank()
                || idToken.textValue().length() > 16 * 1024) {
            throw new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
        }
        return idToken.textValue();
    }

    private static boolean printable(String value) {
        return value.chars().allMatch(character -> character >= 33 && character <= 126);
    }
}
