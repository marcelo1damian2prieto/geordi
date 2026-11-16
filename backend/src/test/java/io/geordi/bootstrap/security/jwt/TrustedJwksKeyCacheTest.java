package io.geordi.bootstrap.security.jwt;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.bootstrap.security.SecurityFailure;
import java.math.BigInteger;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class TrustedJwksKeyCacheTest {
    private static KeyPair first;
    private static KeyPair second;
    private static final Instant START = Instant.parse("2026-01-02T03:04:05Z");

    @BeforeAll
    static void generateKeys() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        first = generator.generateKeyPair();
        second = generator.generateKeyPair();
    }

    @Test
    void startupLoadsUsableKeyAndSuccessfulRefreshAtomicallyRemovesOldKeys() {
        MutableClock clock = new MutableClock(START);
        AtomicReference<String> document = new AtomicReference<>(jwks("key-1", first));
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(document::get, clock);
        cache.initialize();
        assertThat(cache.resolve("key-1")).isEqualTo(first.getPublic());

        document.set(jwks("key-2", second));
        clock.advance(Duration.ofMinutes(5));
        assertThat(cache.resolve("key-2")).isEqualTo(second.getPublic());
        assertThatThrownBy(() -> cache.resolve("key-1")).isInstanceOf(SecurityFailure.class)
                .extracting(failure -> ((SecurityFailure) failure).kind())
                .isEqualTo(SecurityFailure.Kind.INVALID_AUTHENTICATION);
    }

    @Test
    void unknownKidRefreshIsRateLimitedAndCoalesced() {
        MutableClock clock = new MutableClock(START);
        AtomicInteger fetches = new AtomicInteger();
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(() -> {
            fetches.incrementAndGet();
            return jwks("key-1", first);
        }, clock);
        cache.initialize();

        assertInvalid(() -> cache.resolve("unknown"));
        assertInvalid(() -> cache.resolve("unknown"));
        assertThat(fetches.get()).isEqualTo(2);
        clock.advance(Duration.ofSeconds(30));
        assertInvalid(() -> cache.resolve("unknown"));
        assertThat(fetches.get()).isEqualTo(3);
    }

    @Test
    void keepsOnlyBoundedStaleKeysDuringRefreshFailure() {
        MutableClock clock = new MutableClock(START);
        AtomicReference<Boolean> unavailable = new AtomicReference<>(false);
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(() -> {
            if (unavailable.get()) throw new IllegalStateException("private fetch failure");
            return jwks("key-1", first);
        }, clock);
        cache.initialize();
        unavailable.set(true);
        clock.advance(Duration.ofMinutes(6));
        assertThat(cache.resolve("key-1")).isEqualTo(first.getPublic());
        clock.advance(Duration.ofMinutes(9).plusSeconds(1));
        assertThatThrownBy(() -> cache.resolve("key-1")).isInstanceOf(SecurityFailure.class)
                .extracting(failure -> ((SecurityFailure) failure).kind())
                .isEqualTo(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
    }

    @Test
    void coalescesFailedRefreshAndKeepsCachedKeyAvailableWhileRefreshIsInFlight() throws Exception {
        MutableClock clock = new MutableClock(START);
        CountDownLatch refreshStarted = new CountDownLatch(1);
        CountDownLatch releaseRefresh = new CountDownLatch(1);
        AtomicInteger fetches = new AtomicInteger();
        AtomicReference<Boolean> unavailable = new AtomicReference<>(false);
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(() -> {
            fetches.incrementAndGet();
            if (unavailable.get()) {
                refreshStarted.countDown();
                try {
                    releaseRefresh.await(2, TimeUnit.SECONDS);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("interrupted");
                }
                throw new IllegalStateException("issuer unavailable");
            }
            return jwks("key-1", first);
        }, clock);
        cache.initialize();
        unavailable.set(true);
        clock.advance(Duration.ofMinutes(6));
        var executor = Executors.newSingleThreadExecutor();
        try {
            var refresh = executor.submit(() -> cache.resolve("key-1"));
            assertThat(refreshStarted.await(1, TimeUnit.SECONDS)).isTrue();
            assertThat(cache.resolve("key-1")).isEqualTo(first.getPublic());
            releaseRefresh.countDown();
            assertThat(refresh.get(2, TimeUnit.SECONDS)).isEqualTo(first.getPublic());
            assertThat(cache.resolve("key-1")).isEqualTo(first.getPublic());
            assertThat(fetches.get()).isEqualTo(2);
        } finally {
            releaseRefresh.countDown();
            executor.shutdownNow();
        }
    }

    @Test
    void expiredKeyCannotBeUsedWhileFailedRefreshIsInFlight() throws Exception {
        MutableClock clock = new MutableClock(START);
        CountDownLatch refreshStarted = new CountDownLatch(1);
        CountDownLatch secondResolveStarted = new CountDownLatch(1);
        CountDownLatch releaseRefresh = new CountDownLatch(1);
        AtomicInteger fetches = new AtomicInteger();
        AtomicReference<Boolean> unavailable = new AtomicReference<>(false);
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(() -> {
            fetches.incrementAndGet();
            if (unavailable.get()) {
                refreshStarted.countDown();
                try {
                    releaseRefresh.await(2, TimeUnit.SECONDS);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("interrupted");
                }
                throw new IllegalStateException("issuer unavailable");
            }
            return jwks("key-1", first);
        }, clock);
        cache.initialize();
        unavailable.set(true);
        clock.advance(Duration.ofMinutes(16));
        var executor = Executors.newFixedThreadPool(2);
        try {
            var firstResolve = executor.submit(() -> resolveFailure(cache));
            assertThat(refreshStarted.await(1, TimeUnit.SECONDS)).isTrue();
            var secondResolve = executor.submit(() -> {
                secondResolveStarted.countDown();
                return resolveFailure(cache);
            });
            assertThat(secondResolveStarted.await(1, TimeUnit.SECONDS)).isTrue();
            Thread.sleep(50);
            assertThat(secondResolve.isDone()).isFalse();
            releaseRefresh.countDown();
            assertThat(firstResolve.get(2, TimeUnit.SECONDS))
                    .isEqualTo(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
            assertThat(secondResolve.get(2, TimeUnit.SECONDS))
                    .isEqualTo(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
            assertThat(fetches.get()).isEqualTo(2);
        } finally {
            releaseRefresh.countDown();
            executor.shutdownNow();
        }
    }

    @Test
    void unknownKidRemainsDependencyFailureDuringFailedRefreshCooldown() {
        MutableClock clock = new MutableClock(START);
        AtomicInteger fetches = new AtomicInteger();
        AtomicReference<Boolean> unavailable = new AtomicReference<>(false);
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(() -> {
            fetches.incrementAndGet();
            if (unavailable.get()) throw new IllegalStateException("issuer unavailable");
            return jwks("key-1", first);
        }, clock);
        cache.initialize();
        unavailable.set(true);
        assertDependencyUnavailable(() -> cache.resolve("unknown"));
        assertDependencyUnavailable(() -> cache.resolve("another-unknown"));
        assertThat(fetches.get()).isEqualTo(2);
    }

    @Test
    void rejectsDuplicateKeyIdsAndWeakRsaMaterialAtStartup() {
        MutableClock clock = new MutableClock(START);
        TrustedJwksKeyCache duplicate = new TrustedJwksKeyCache(
                () -> jwks("key-1", first, "key-1", second), clock);
        assertInvalid(duplicate::initialize);
        TrustedJwksKeyCache oversized = new TrustedJwksKeyCache(() -> "{" + "x".repeat(262145) + "}", clock);
        assertInvalid(oversized::initialize);
    }

    private static String jwks(String id, KeyPair key) {
        return jwks(id, key, null, null);
    }

    private static String jwks(String firstId, KeyPair firstKey, String secondId, KeyPair secondKey) {
        String firstJwk = jwk(firstId, firstKey);
        String entries = secondKey == null ? firstJwk : firstJwk + "," + jwk(secondId, secondKey);
        return "{\"keys\":[" + entries + "]}";
    }

    private static String jwk(String id, KeyPair key) {
        RSAPublicKey rsa = (RSAPublicKey) key.getPublic();
        return "{\"kid\":\"" + id + "\",\"kty\":\"RSA\",\"use\":\"sig\",\"alg\":\"RS256\","
                + "\"n\":\"" + base64(unsigned(rsa.getModulus())) + "\",\"e\":\""
                + base64(unsigned(rsa.getPublicExponent())) + "\"}";
    }

    private static byte[] unsigned(BigInteger value) {
        byte[] bytes = value.toByteArray();
        return bytes.length > 1 && bytes[0] == 0 ? java.util.Arrays.copyOfRange(bytes, 1, bytes.length) : bytes;
    }

    private static String base64(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    private static void assertInvalid(Runnable call) {
        assertThatThrownBy(call::run).isInstanceOf(SecurityFailure.class);
    }

    private static void assertDependencyUnavailable(Runnable call) {
        assertThatThrownBy(call::run).isInstanceOf(SecurityFailure.class)
                .extracting(failure -> ((SecurityFailure) failure).kind())
                .isEqualTo(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
    }

    private static SecurityFailure.Kind resolveFailure(TrustedJwksKeyCache cache) {
        try {
            cache.resolve("key-1");
            throw new AssertionError("expired key was accepted");
        } catch (SecurityFailure failure) {
            return failure.kind();
        }
    }

    private static final class MutableClock extends Clock {
        private final AtomicReference<Instant> instant;

        private MutableClock(Instant initial) {
            instant = new AtomicReference<>(initial);
        }

        void advance(Duration duration) {
            instant.updateAndGet(value -> value.plus(duration));
        }

        @Override
        public ZoneId getZone() {
            return ZoneId.of("UTC");
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return instant.get();
        }
    }
}
