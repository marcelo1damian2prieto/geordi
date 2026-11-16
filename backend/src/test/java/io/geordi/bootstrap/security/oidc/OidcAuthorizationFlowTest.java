package io.geordi.bootstrap.security.oidc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.ExternalGrantMapper;
import io.geordi.bootstrap.security.PublicOrigin;
import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.bootstrap.security.metadata.TrustedIssuerMetadata;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.AuthenticationMechanism;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class OidcAuthorizationFlowTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Instant NOW = Instant.parse("2026-01-02T03:04:05Z");
    private static KeyPair signingKey;

    @BeforeAll
    static void key() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        signingKey = generator.generateKeyPair();
    }

    @Test
    void usesFixedCodePkceStateNonceCallbackAndCreatesOnlyCanonicalSession() throws Exception {
        BoundedSessionStore sessions = new BoundedSessionStore(Clock.fixed(NOW, ZoneOffset.UTC),
                new java.security.SecureRandom());
        AtomicReference<String> receivedVerifier = new AtomicReference<>();
        AtomicReference<URI> receivedRedirect = new AtomicReference<>();
        AtomicReference<String> idToken = new AtomicReference<>();
        OidcAuthorizationFlow flow = flow(sessions, (code, verifier, redirect) -> {
            assertThat(code).isEqualTo("one-time-code");
            receivedVerifier.set(verifier);
            receivedRedirect.set(redirect);
            return idToken.get();
        });

        URI redirect = flow.beginLogin();
        Map<String, String> query = query(redirect);
        assertThat(query.get("response_type")).isEqualTo("code");
        assertThat(query.get("response_mode")).isEqualTo("query");
        assertThat(query.get("scope")).isEqualTo("openid profile");
        assertThat(query).doesNotContainKey("offline_access");
        assertThat(query.get("redirect_uri")).isEqualTo("https://geordi.example/login/oauth2/code/geordi");
        assertThat(query.get("code_challenge_method")).isEqualTo("S256");
        idToken.set(idToken(query.get("nonce"), "JWT"));

        String sessionId = flow.completeCallback(query.get("state"), "one-time-code");
        var principal = sessions.resolve(sessionId);
        assertThat(principal).isNotNull();
        assertThat(principal.mechanism()).isEqualTo(AuthenticationMechanism.SESSION);
        assertThat(principal.identity().subject()).isEqualTo("browser-operator");
        assertThat(receivedVerifier.get()).hasSize(43);
        assertThat(query.get("code_challenge")).isEqualTo(pkceChallenge(receivedVerifier.get()));
        assertThat(receivedRedirect.get()).isEqualTo(URI.create(query.get("redirect_uri")));
        assertThat(sessions.pendingCount()).isZero();
        assertThatThrownBy(() -> flow.completeCallback(query.get("state"), "replayed-code"))
                .isInstanceOf(SecurityFailure.class);
    }

    @Test
    void rejectsNonceMismatchAndDiscardsClaimedTransaction() throws Exception {
        BoundedSessionStore sessions = new BoundedSessionStore(Clock.fixed(NOW, ZoneOffset.UTC),
                new java.security.SecureRandom());
        String wrongIdToken = idToken("wrong-nonce", "JWT");
        OidcAuthorizationFlow flow = flow(sessions, (code, verifier, redirect) -> wrongIdToken);
        URI redirect = flow.beginLogin();
        String state = query(redirect).get("state");

        assertThatThrownBy(() -> flow.completeCallback(state, "code"))
                .isInstanceOf(SecurityFailure.class)
                .satisfies(failure -> assertThat(((SecurityFailure) failure).kind())
                        .isEqualTo(SecurityFailure.Kind.INVALID_AUTHENTICATION));
        assertThat(sessions.pendingCount()).isZero();
        assertThat(sessions.sessionCount()).isZero();
    }

    @Test
    void releasesCapacityAfterTokenEndpointFailureWithoutRetainingTransaction() throws Exception {
        BoundedSessionStore sessions = new BoundedSessionStore(Clock.fixed(NOW, ZoneOffset.UTC),
                new java.security.SecureRandom());
        OidcAuthorizationFlow flow = flow(sessions, (code, verifier, redirect) -> {
            throw new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
        });
        String state = query(flow.beginLogin()).get("state");

        assertThatThrownBy(() -> flow.completeCallback(state, "code")).isInstanceOf(SecurityFailure.class);
        assertThat(sessions.pendingCount()).isZero();
    }

    @Test
    void reauthenticationInvalidatesThePriorCookieIdentifierWhenTheNewSessionIsAdmitted() throws Exception {
        BoundedSessionStore sessions = new BoundedSessionStore(Clock.fixed(NOW, ZoneOffset.UTC),
                new java.security.SecureRandom());
        String prior = sessions.createSession(new io.geordi.core.application.security.AuthenticatedPrincipal(
                new io.geordi.core.application.security.PrincipalIdentity("https://issuer.example", "old-subject"),
                null, Set.of(), AuthenticationMechanism.SESSION));
        AtomicReference<String> signedIdToken = new AtomicReference<>();
        OidcAuthorizationFlow flow = flow(sessions, (code, verifier, redirect) -> signedIdToken.get());
        URI redirect = flow.beginLogin(prior);
        Map<String, String> query = query(redirect);
        signedIdToken.set(idToken(query.get("nonce"), "JWT"));

        String rotated = flow.completeCallback(query.get("state"), "code");
        assertThat(rotated).isNotEqualTo(prior);
        assertThat(sessions.resolve(prior)).isNull();
        assertThat(sessions.resolve(rotated)).isNotNull();
    }

    private static OidcAuthorizationFlow flow(BoundedSessionStore sessions, AuthorizationCodeTokenExchange exchange) {
        String issuer = "https://issuer.example";
        var keys = (io.geordi.bootstrap.security.jwt.TrustedAccessTokenKeyResolver)
                kid -> "key-1".equals(kid) ? signingKey.getPublic() : null;
        var validator = new OidcIdTokenValidator(issuer, "browser-client", "permissions",
                new ExternalGrantMapper(Map.of("viewer", Set.of(io.geordi.core.application.security.GeordiPermission.OBSERVABILITY_READ))),
                keys, Clock.fixed(NOW, ZoneOffset.UTC));
        var metadata = new TrustedIssuerMetadata(issuer, URI.create("https://auth.example/authorize?tenant=geordi"),
                URI.create("https://auth.example/token"), URI.create("https://auth.example/keys"));
        return new OidcAuthorizationFlow(sessions, new PublicOrigin("https://geordi.example"),
                () -> metadata, exchange, validator, "browser-client");
    }

    private static Map<String, String> query(URI uri) {
        Map<String, String> result = new HashMap<>();
        for (String pair : uri.getRawQuery().split("&")) {
            String[] parts = pair.split("=", 2);
            result.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8),
                    URLDecoder.decode(parts.length > 1 ? parts[1] : "", StandardCharsets.UTF_8));
        }
        return result;
    }

    private static String pkceChallenge(String verifier) throws Exception {
        byte[] digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(verifier.getBytes(StandardCharsets.US_ASCII));
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
    }

    private static String idToken(String nonce, String type) throws Exception {
        Map<String, Object> header = Map.of("alg", "RS256", "typ", type, "kid", "key-1");
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", "https://issuer.example");
        claims.put("sub", "browser-operator");
        claims.put("aud", "browser-client");
        claims.put("exp", NOW.getEpochSecond() + 300);
        claims.put("iat", NOW.getEpochSecond());
        claims.put("nonce", nonce);
        claims.put("name", "Browser Operator");
        claims.put("permissions", java.util.List.of("viewer"));
        String h = encode(JSON.writeValueAsBytes(header));
        String p = encode(JSON.writeValueAsBytes(claims));
        String signingInput = h + "." + p;
        Signature signature = Signature.getInstance("SHA256withRSA");
        signature.initSign(signingKey.getPrivate());
        signature.update(signingInput.getBytes(StandardCharsets.US_ASCII));
        return signingInput + "." + encode(signature.sign());
    }

    private static String encode(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }
}
