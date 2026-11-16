package io.geordi.bootstrap.security.jwt;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.ExternalGrantMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.PrincipalIdentity;
import java.nio.charset.StandardCharsets;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.time.Clock;
import java.util.Base64;
import java.util.HashSet;
import java.util.Set;

/** Explicit bounded RFC 9068 profile; provider defaults do not define acceptance. */
public final class AccessTokenProfile implements BearerTokenAuthenticator {
    private static final int MAX_TOKEN_BYTES = 16 * 1024;
    private static final long CLOCK_SKEW_SECONDS = 60;
    private static final long MAX_LIFETIME_SECONDS = 3600;
    private static final ObjectMapper JSON = new ObjectMapper(JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build());

    private final String issuer;
    private final String audience;
    private final String grantClaim;
    private final ExternalGrantMapper grants;
    private final TrustedAccessTokenKeyResolver keys;
    private final Clock clock;

    public AccessTokenProfile(String issuer, String audience, String grantClaim,
            ExternalGrantMapper grants, TrustedAccessTokenKeyResolver keys, Clock clock) {
        this.issuer = issuer;
        this.audience = audience;
        this.grantClaim = grantClaim;
        this.grants = grants;
        this.keys = keys;
        this.clock = clock;
    }

    @Override
    public AuthenticatedPrincipal authenticate(String token) {
        try {
            if (token == null || token.length() > MAX_TOKEN_BYTES
                    || !StandardCharsets.US_ASCII.newEncoder().canEncode(token)) throw SecurityFailure.invalid();
            String[] segments = token.split("\\.", -1);
            if (segments.length != 3 || segments[0].isEmpty() || segments[1].isEmpty() || segments[2].isEmpty()) {
                throw SecurityFailure.invalid();
            }
            JsonNode header = json(segments[0]);
            JsonNode claims = json(segments[1]);
            if (!header.isObject() || !claims.isObject()) throw SecurityFailure.invalid();
            validateHeader(header);
            validateClaims(claims);
            if (!segments[2].matches("[A-Za-z0-9_-]+")) throw SecurityFailure.invalid();
            byte[] signature = Base64.getUrlDecoder().decode(segments[2]);

            String keyId = header.get("kid").textValue();
            var key = keys.resolve(keyId);
            if (!(key instanceof RSAPublicKey rsa) || rsa.getModulus().bitLength() < 2048) {
                throw SecurityFailure.invalid();
            }
            Signature verifier = Signature.getInstance("SHA256withRSA");
            verifier.initVerify(rsa);
            verifier.update((segments[0] + "." + segments[1]).getBytes(StandardCharsets.US_ASCII));
            if (!verifier.verify(signature)) throw SecurityFailure.invalid();

            String subject = claims.get("sub").textValue();
            String display = claims.has("name") && claims.get("name").isTextual()
                    ? claims.get("name").textValue() : null;
            boolean hasGrants = claims.has(grantClaim);
            Set<io.geordi.core.application.security.GeordiPermission> permissions = grants.map(
                    hasGrants, hasGrants ? JSON.convertValue(claims.get(grantClaim), Object.class) : null);
            return new AuthenticatedPrincipal(new PrincipalIdentity(issuer, subject), display,
                    permissions, AuthenticationMechanism.BEARER);
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            throw SecurityFailure.invalid();
        }
    }

    private void validateHeader(JsonNode header) {
        String algorithm = text(header, "alg");
        String type = text(header, "typ");
        String keyId = text(header, "kid");
        if (!"RS256".equals(algorithm) || !("at+jwt".equals(type) || "application/at+jwt".equals(type))
                || keyId.isEmpty() || keyId.length() > 128 || !printable(keyId)
                || header.has("crit") || header.has("jku") || header.has("jwk")
                || header.has("x5u") || header.has("x5c")) throw SecurityFailure.invalid();
    }

    private void validateClaims(JsonNode claims) {
        if (!issuer.equals(text(claims, "iss"))) throw SecurityFailure.invalid();
        String subject = text(claims, "sub");
        String client = text(claims, "client_id");
        String jwtId = text(claims, "jti");
        if (subject.isEmpty() || !boundedPrintable(client) || !boundedPrintable(jwtId)
                || !hasAudience(claims.get("aud"), audience)) throw SecurityFailure.invalid();
        long issued = number(claims, "iat");
        long expiry = number(claims, "exp");
        long now = clock.instant().getEpochSecond();
        long lifetime;
        try {
            lifetime = Math.subtractExact(expiry, issued);
        } catch (ArithmeticException overflow) {
            throw SecurityFailure.invalid();
        }
        if (issued > now + CLOCK_SKEW_SECONDS || expiry < now - CLOCK_SKEW_SECONDS
                || expiry <= issued || lifetime > MAX_LIFETIME_SECONDS) throw SecurityFailure.invalid();
        if (claims.has("nbf") && number(claims, "nbf") > now + CLOCK_SKEW_SECONDS) throw SecurityFailure.invalid();
        try {
            new PrincipalIdentity(issuer, subject);
        } catch (IllegalArgumentException failure) {
            throw SecurityFailure.invalid();
        }
    }

    private static boolean hasAudience(JsonNode audienceNode, String expected) {
        if (audienceNode == null) return false;
        if (audienceNode.isTextual()) return expected.equals(audienceNode.textValue());
        if (!audienceNode.isArray() || audienceNode.isEmpty()) return false;
        Set<String> values = new HashSet<>();
        for (JsonNode value : audienceNode) {
            if (!value.isTextual() || !values.add(value.textValue())) return false;
        }
        return values.contains(expected);
    }

    private static JsonNode json(String encoded) throws Exception {
        if (!encoded.matches("[A-Za-z0-9_-]+")) throw SecurityFailure.invalid();
        byte[] bytes = Base64.getUrlDecoder().decode(encoded);
        JsonNode value = JSON.readTree(bytes);
        if (value == null) throw SecurityFailure.invalid();
        return value;
    }

    private static long number(JsonNode object, String name) {
        JsonNode value = object.get(name);
        if (value == null || !value.isIntegralNumber() || !value.canConvertToLong()) throw SecurityFailure.invalid();
        return value.longValue();
    }

    private static String text(JsonNode object, String name) {
        JsonNode value = object.get(name);
        if (value == null || !value.isTextual()) throw SecurityFailure.invalid();
        return value.textValue();
    }

    private static boolean boundedPrintable(String value) {
        return !value.isEmpty() && value.length() <= 255 && printable(value);
    }

    private static boolean printable(String value) {
        return value.chars().allMatch(character -> character >= 33 && character <= 126);
    }
}
