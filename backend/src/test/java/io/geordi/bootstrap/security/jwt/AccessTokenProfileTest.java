package io.geordi.bootstrap.security.jwt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.ExternalGrantMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.GeordiPermission;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class AccessTokenProfileTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Clock CLOCK = Clock.fixed(Instant.parse("2026-01-02T03:04:05Z"), ZoneOffset.UTC);
    private static KeyPair signingKey;

    @BeforeAll
    static void generateKey() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        signingKey = generator.generateKeyPair();
    }

    @Test
    void acceptsSignedAccessTokenAndMapsOnlyExplicitGrant() throws Exception {
        var principal = profile().authenticate(token(header(), claims(), true));

        assertThat(principal.identity().issuer()).isEqualTo("https://issuer.example");
        assertThat(principal.identity().subject()).isEqualTo("operator-17");
        assertThat(principal.displayName()).isEqualTo("Operator");
        assertThat(principal.permissions()).containsOnly(GeordiPermission.ALERT_ACKNOWLEDGE);
        assertThat(principal.mechanism()).isEqualTo(AuthenticationMechanism.BEARER);
    }

    @Test
    void rejectsIdTokenPurposeAndUnsupportedSignatureAlgorithms() throws Exception {
        var idHeader = header();
        idHeader.put("typ", "JWT");
        assertInvalid(token(idHeader, claims(), true));

        var hmac = header();
        hmac.put("alg", "HS256");
        assertInvalid(token(hmac, claims(), true));

        var none = header();
        none.put("alg", "none");
        assertInvalid(token(none, claims(), false));
    }

    @Test
    void rejectsWrongAudienceLifetimeAndFutureNotBefore() throws Exception {
        var wrongAudience = claims();
        wrongAudience.put("aud", "another-api");
        assertInvalid(token(header(), wrongAudience, true));

        var longLived = claims();
        longLived.put("exp", 1767326646L);
        assertInvalid(token(header(), longLived, true));

        var future = claims();
        future.put("nbf", 1767323106L);
        assertInvalid(token(header(), future, true));

        var overflowingLifetime = claims();
        overflowingLifetime.put("iat", -1L);
        overflowingLifetime.put("exp", Long.MAX_VALUE);
        assertInvalid(token(header(), overflowingLifetime, true));
    }

    @Test
    void rejectsDuplicateMembersAndTokenSelectedKeys() throws Exception {
        String duplicatePayload = "{\"iss\":\"https://issuer.example\",\"iss\":\"https://issuer.example\"}";
        assertInvalid(rawToken(header(), duplicatePayload, true));

        var selected = header();
        selected.put("jku", "https://attacker.invalid/jwks");
        assertInvalid(token(selected, claims(), true));

        var critical = header();
        critical.put("crit", List.of("exp"));
        assertInvalid(token(critical, claims(), true));
    }

    @Test
    void rejectsMalformedGrantClaimAndInvalidSignature() throws Exception {
        var malformed = claims();
        malformed.put("permissions", "alerts:acknowledge");
        assertInvalid(token(header(), malformed, true));

        String valid = token(header(), claims(), true);
        assertInvalid(valid.substring(0, valid.length() - 4) + "AAAA");
    }

    @Test
    void rejectsOversizedAndEncryptedOrMalformedCompactTokensBeforeKeyLookup() throws Exception {
        assertInvalid("x".repeat(16 * 1024 + 1));
        assertInvalid("one.two.three.four.five");
        var badKid = header();
        badKid.remove("kid");
        assertInvalid(token(badKid, claims(), true));
    }

    private static AccessTokenProfile profile() {
        var mapper = new ExternalGrantMapper(Map.of("operator", java.util.Set.of(GeordiPermission.ALERT_ACKNOWLEDGE)));
        return new AccessTokenProfile("https://issuer.example", "geordi-api", "permissions", mapper,
                kid -> "key-1".equals(kid) ? signingKey.getPublic() : null, CLOCK);
    }

    private static Map<String, Object> header() {
        return new LinkedHashMap<>(Map.of("alg", "RS256", "typ", "at+jwt", "kid", "key-1"));
    }

    private static Map<String, Object> claims() {
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", "https://issuer.example");
        claims.put("sub", "operator-17");
        claims.put("aud", List.of("geordi-api"));
        claims.put("exp", 1767323345L);
        claims.put("iat", 1767323045L);
        claims.put("client_id", "ci-client");
        claims.put("jti", "token-unique-17");
        claims.put("permissions", List.of("operator", "unrecognized"));
        claims.put("name", "Operator");
        return claims;
    }

    private static String token(Map<String, Object> header, Map<String, Object> claims, boolean sign) throws Exception {
        return rawToken(header, JSON.writeValueAsString(claims), sign);
    }

    private static String rawToken(Map<String, Object> header, String payload, boolean sign) throws Exception {
        String encodedHeader = base64(JSON.writeValueAsString(header).getBytes(StandardCharsets.UTF_8));
        String encodedPayload = base64(payload.getBytes(StandardCharsets.UTF_8));
        String signingInput = encodedHeader + "." + encodedPayload;
        if (!sign) return signingInput + ".AA";
        Signature signature = Signature.getInstance("SHA256withRSA");
        signature.initSign(signingKey.getPrivate());
        signature.update(signingInput.getBytes(StandardCharsets.US_ASCII));
        return signingInput + "." + base64(signature.sign());
    }

    private static String base64(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static void assertInvalid(String token) {
        assertThatThrownBy(() -> profile().authenticate(token)).isInstanceOf(SecurityFailure.class)
                .hasMessage("Security request failed")
                .satisfies(failure -> assertThat(((SecurityFailure) failure).kind())
                        .isEqualTo(SecurityFailure.Kind.INVALID_AUTHENTICATION));
    }
}
