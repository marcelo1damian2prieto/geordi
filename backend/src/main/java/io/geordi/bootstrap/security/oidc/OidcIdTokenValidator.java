package io.geordi.bootstrap.security.oidc;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.ExternalGrantMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.bootstrap.security.jwt.TrustedAccessTokenKeyResolver;
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

/** Validates the OIDC identity-token purpose independently of the RFC 9068 access-token profile. */
public final class OidcIdTokenValidator {
    private static final int MAX_TOKEN_BYTES = 16 * 1024;
    private static final long SKEW_SECONDS = 60;
    private static final ObjectMapper JSON = new ObjectMapper(JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build());

    private final String issuer;
    private final String clientId;
    private final String grantClaim;
    private final ExternalGrantMapper grants;
    private final TrustedAccessTokenKeyResolver keys;
    private final Clock clock;

    public OidcIdTokenValidator(String issuer, String clientId, String grantClaim,
            ExternalGrantMapper grants, TrustedAccessTokenKeyResolver keys, Clock clock) {
        this.issuer = issuer;
        this.clientId = clientId;
        this.grantClaim = grantClaim;
        this.grants = grants;
        this.keys = keys;
        this.clock = clock;
    }

    public AuthenticatedPrincipal validate(String token, String expectedNonce) {
        try {
            if (token == null || token.length() > MAX_TOKEN_BYTES
                    || !StandardCharsets.US_ASCII.newEncoder().canEncode(token)) throw SecurityFailure.invalid();
            String[] parts = token.split("\\.", -1);
            if (parts.length != 3 || parts[0].isEmpty() || parts[1].isEmpty() || parts[2].isEmpty()) {
                throw SecurityFailure.invalid();
            }
            JsonNode header = json(parts[0]);
            JsonNode claims = json(parts[1]);
            if (!header.isObject() || !claims.isObject()) throw SecurityFailure.invalid();
            String type = optionalText(header, "typ");
            String keyId = text(header, "kid");
            if (!"RS256".equals(text(header, "alg")) || !(type.isEmpty() || "JWT".equals(type))
                    || keyId.isEmpty() || keyId.length() > 128 || header.has("crit") || header.has("jku")
                    || header.has("jwk") || header.has("x5u") || header.has("x5c")) throw SecurityFailure.invalid();
            validateClaims(claims, expectedNonce);
            if (!parts[2].matches("[A-Za-z0-9_-]+")) throw SecurityFailure.invalid();
            byte[] signature = Base64.getUrlDecoder().decode(parts[2]);
            var key = keys.resolve(keyId);
            if (!(key instanceof RSAPublicKey rsa) || rsa.getModulus().bitLength() < 2048) {
                throw SecurityFailure.invalid();
            }
            Signature verifier = Signature.getInstance("SHA256withRSA");
            verifier.initVerify(rsa);
            verifier.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
            if (!verifier.verify(signature)) throw SecurityFailure.invalid();

            String subject = text(claims, "sub");
            String name = optionalText(claims, "name");
            boolean hasGrants = claims.has(grantClaim);
            var permissions = grants.map(hasGrants,
                    hasGrants ? JSON.convertValue(claims.get(grantClaim), Object.class) : null);
            return new AuthenticatedPrincipal(new PrincipalIdentity(issuer, subject), name.isEmpty() ? null : name,
                    permissions, AuthenticationMechanism.SESSION);
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            throw SecurityFailure.invalid();
        }
    }

    private void validateClaims(JsonNode claims, String expectedNonce) {
        if (!issuer.equals(text(claims, "iss")) || expectedNonce == null || expectedNonce.isEmpty()
                || !expectedNonce.equals(text(claims, "nonce")) || !hasAudience(claims.get("aud"), clientId)) {
            throw SecurityFailure.invalid();
        }
        JsonNode audience = claims.get("aud");
        if (audience.isArray() && audience.size() > 1 && !clientId.equals(text(claims, "azp"))) {
            throw SecurityFailure.invalid();
        }
        if (claims.has("azp") && !clientId.equals(text(claims, "azp"))) throw SecurityFailure.invalid();
        long issued = number(claims, "iat");
        long expiry = number(claims, "exp");
        long now = clock.instant().getEpochSecond();
        if (issued > now + SKEW_SECONDS || expiry < now - SKEW_SECONDS || expiry <= issued
                || claims.has("nbf") && number(claims, "nbf") > now + SKEW_SECONDS) {
            throw SecurityFailure.invalid();
        }
    }

    private static boolean hasAudience(JsonNode node, String expected) {
        if (node == null) return false;
        if (node.isTextual()) return expected.equals(node.textValue());
        if (!node.isArray() || node.isEmpty()) return false;
        Set<String> audiences = new HashSet<>();
        for (JsonNode item : node) {
            if (!item.isTextual() || !audiences.add(item.textValue())) return false;
        }
        return audiences.contains(expected);
    }

    private static JsonNode json(String encoded) throws Exception {
        if (!encoded.matches("[A-Za-z0-9_-]+")) throw SecurityFailure.invalid();
        JsonNode node = JSON.readTree(Base64.getUrlDecoder().decode(encoded));
        if (node == null) throw SecurityFailure.invalid();
        return node;
    }

    private static long number(JsonNode claims, String field) {
        JsonNode value = claims.get(field);
        if (value == null || !value.isIntegralNumber() || !value.canConvertToLong()) throw SecurityFailure.invalid();
        return value.longValue();
    }

    private static String optionalText(JsonNode object, String field) {
        JsonNode value = object.get(field);
        if (value == null) return "";
        if (!value.isTextual()) throw SecurityFailure.invalid();
        return value.textValue();
    }

    private static String text(JsonNode object, String field) {
        String value = optionalText(object, field);
        if (value.isEmpty()) throw SecurityFailure.invalid();
        return value;
    }
}
