package io.geordi.bootstrap.security.jwt;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.spec.RSAPublicKeySpec;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.locks.ReentrantLock;

/** Atomic replace cache with a bounded stale window and coalesced refreshes. */
public final class TrustedJwksKeyCache implements TrustedAccessTokenKeyResolver {
    private static final int MAX_BYTES = 256 * 1024;
    private static final Duration REFRESH_INTERVAL = Duration.ofMinutes(5);
    private static final Duration MAXIMUM_AGE = Duration.ofMinutes(15);
    private static final Duration UNKNOWN_KEY_INTERVAL = Duration.ofSeconds(30);
    private static final ObjectMapper JSON = new ObjectMapper(JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build());

    private final JwksDocumentFetcher fetcher;
    private final Clock clock;
    private volatile Map<String, PublicKey> keys = Map.of();
    private volatile Instant refreshedAt;
    private volatile Instant lastRefreshAttemptAt;
    private volatile boolean lastRefreshFailed;
    private Instant lastUnknownRefreshAt;
    private boolean lastUnknownRefreshFailed;
    private final ReentrantLock refreshLock = new ReentrantLock();

    public TrustedJwksKeyCache(JwksDocumentFetcher fetcher, Clock clock) {
        this.fetcher = fetcher;
        this.clock = clock;
    }

    /** Startup must call this and fail when metadata has no usable trusted signing key. */
    public void initialize() {
        if (!refresh(false)) throw unavailable();
    }

    @Override
    public PublicKey resolve(String keyId) {
        if (keys.isEmpty()) throw unavailable();
        Instant now = clock.instant();
        PublicKey key = keys.get(keyId);
        Duration age = Duration.between(refreshedAt, now);
        if (age.compareTo(REFRESH_INTERVAL) >= 0 && (key == null || age.compareTo(MAXIMUM_AGE) > 0)) {
            boolean expired = age.compareTo(MAXIMUM_AGE) > 0;
            boolean refreshed = refresh(!expired);
            if (!refreshed && expired) throw unavailable();
            key = keys.get(keyId);
        } else if (age.compareTo(REFRESH_INTERVAL) >= 0) {
            refresh(true);
            key = keys.get(keyId);
        }
        if (key != null) return key;
        synchronized (this) {
            now = clock.instant();
            if (lastUnknownRefreshAt == null
                    || Duration.between(lastUnknownRefreshAt, now).compareTo(UNKNOWN_KEY_INTERVAL) >= 0) {
                lastUnknownRefreshAt = now;
                if (lastRefreshFailed && lastRefreshAttemptAt != null
                        && Duration.between(lastRefreshAttemptAt, now).compareTo(REFRESH_INTERVAL) < 0) {
                    lastUnknownRefreshFailed = true;
                } else {
                    lastUnknownRefreshFailed = !refresh(false, true);
                }
                if (lastUnknownRefreshFailed) throw unavailable();
            } else if (lastUnknownRefreshFailed) {
                throw unavailable();
            }
        }
        key = keys.get(keyId);
        if (key == null) throw SecurityFailure.invalid();
        return key;
    }

    private boolean refresh(boolean background) {
        return refresh(background, false);
    }

    private boolean refresh(boolean background, boolean force) {
        if (background && !refreshLock.tryLock()) return true;
        if (!background) refreshLock.lock();
        try {
            Instant now = clock.instant();
            if (!force && lastRefreshAttemptAt != null
                    && Duration.between(lastRefreshAttemptAt, now).compareTo(REFRESH_INTERVAL) < 0) {
                return !lastRefreshFailed;
            }
            lastRefreshAttemptAt = now;
            replaceFrom(fetcher.fetch());
            lastRefreshFailed = false;
            return true;
        } catch (RuntimeException failure) {
            lastRefreshFailed = true;
            return false;
        } finally {
            refreshLock.unlock();
        }
    }

    private void replaceFrom(String document) {
        try {
            if (document == null || document.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) {
                throw SecurityFailure.invalid();
            }
            JsonNode root = JSON.readTree(document);
            JsonNode jwkSet = root == null ? null : root.get("keys");
            if (jwkSet == null || !jwkSet.isArray() || jwkSet.isEmpty() || jwkSet.size() > 32) {
                throw SecurityFailure.invalid();
            }
            Map<String, PublicKey> replacement = new HashMap<>();
            Set<String> allIds = new HashSet<>();
            for (JsonNode jwk : jwkSet) {
                String id = text(jwk, "kid");
                if (id.isEmpty() || id.length() > 128 || !allIds.add(id)) throw SecurityFailure.invalid();
                if (!"RSA".equals(text(jwk, "kty"))
                        || jwk.has("use") && !"sig".equals(text(jwk, "use"))
                        || jwk.has("alg") && !"RS256".equals(text(jwk, "alg"))) throw SecurityFailure.invalid();
                if (jwk.has("key_ops")) {
                    JsonNode operations = jwk.get("key_ops");
                    if (!operations.isArray() || !containsText(operations, "verify")) throw SecurityFailure.invalid();
                }
                BigInteger modulus = unsigned(jwk, "n");
                BigInteger exponent = unsigned(jwk, "e");
                if (modulus.bitLength() < 2048 || exponent.compareTo(BigInteger.ONE) <= 0 || !exponent.testBit(0)) {
                    throw SecurityFailure.invalid();
                }
                PublicKey publicKey = KeyFactory.getInstance("RSA")
                        .generatePublic(new RSAPublicKeySpec(modulus, exponent));
                replacement.put(id, publicKey);
            }
            keys = Map.copyOf(replacement);
            refreshedAt = clock.instant();
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            throw SecurityFailure.invalid();
        }
    }

    private static boolean containsText(JsonNode array, String expected) {
        for (JsonNode value : array) if (value.isTextual() && expected.equals(value.textValue())) return true;
        return false;
    }

    private static String text(JsonNode object, String member) {
        JsonNode value = object.get(member);
        if (value == null || !value.isTextual()) throw SecurityFailure.invalid();
        return value.textValue();
    }

    private static BigInteger unsigned(JsonNode object, String member) {
        String encoded = text(object, member);
        if (!encoded.matches("[A-Za-z0-9_-]+")) throw SecurityFailure.invalid();
        return new BigInteger(1, Base64.getUrlDecoder().decode(encoded));
    }

    private static SecurityFailure unavailable() {
        return new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
    }
}
