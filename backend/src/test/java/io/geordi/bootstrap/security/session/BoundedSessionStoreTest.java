package io.geordi.bootstrap.security.session;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.PrincipalIdentity;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

class BoundedSessionStoreTest {
    private static final Instant START = Instant.parse("2026-01-02T03:04:05Z");

    @Test
    void createsSingleUseBoundedTransactionsAndFreshRotatedSession() {
        MutableClock clock = new MutableClock(START);
        BoundedSessionStore store = new BoundedSessionStore(clock, new SecureRandom(), 4, 2);
        var transaction = store.beginAuthorization();
        assertThat(transaction.state()).hasSize(43);
        assertThat(transaction.nonce()).hasSize(43);
        assertThat(transaction.codeVerifier()).hasSize(43);
        assertThat(transaction.toString()).doesNotContain(transaction.state(), transaction.nonce(), transaction.codeVerifier());
        var consumed = store.claimAuthorization(transaction.state());
        assertThat(consumed.codeVerifier()).isEqualTo(transaction.codeVerifier());
        assertThatThrownBy(() -> store.claimAuthorization(transaction.state())).isInstanceOf(SecurityFailure.class);

        String sessionId = store.completeAuthorization(transaction.state(), principal());
        assertThat(sessionId).hasSize(43);
        assertThat(store.pendingCount()).isZero();
        assertThat(store.resolve(sessionId)).isEqualTo(principal());
        assertThat(store.sessionCount()).isEqualTo(1);
    }

    @Test
    void rejectsAdmissionAtPendingAndTotalLimitsWithoutEvictingLiveEntries() {
        BoundedSessionStore store = new BoundedSessionStore(new MutableClock(START), new SecureRandom(), 2, 1);
        var pending = store.beginAuthorization();
        assertCapacity(() -> store.beginAuthorization());
        assertThat(store.pendingCount()).isEqualTo(1);
        store.claimAuthorization(pending.state());
        String first = store.completeAuthorization(pending.state(), principal());
        String second = store.createSession(principal());
        assertCapacity(() -> store.createSession(principal()));
        assertThat(store.resolve(first)).isNotNull();
        assertThat(store.resolve(second)).isNotNull();
    }

    @Test
    void rotatesSessionAndCsrfTogetherAndLogoutInvalidatesBoth() {
        BoundedSessionStore store = new BoundedSessionStore(new MutableClock(START), new SecureRandom());
        String oldId = store.createSession(principal());
        String oldCsrf = store.csrfTokenForSession(oldId);
        String newId = store.createSession(principal(), oldId);
        String newCsrf = store.csrfTokenForSession(newId);

        assertThat(newId).isNotEqualTo(oldId);
        assertThat(store.resolve(oldId)).isNull();
        assertThat(store.hasValidCsrfToken(newId, oldCsrf)).isFalse();
        assertThat(store.hasValidCsrfToken(newId, newCsrf)).isTrue();
        store.logout(newId);
        assertThat(store.resolve(newId)).isNull();
        assertThat(store.hasValidCsrfToken(newId, newCsrf)).isFalse();
    }

    @Test
    void repeatedCsrfReadsRemainValidAcrossTabsForOneSession() {
        BoundedSessionStore store = new BoundedSessionStore(new MutableClock(START), new SecureRandom());
        String sessionId = store.createSession(principal());
        String firstTabToken = store.csrfTokenForSession(sessionId);
        String secondTabToken = store.csrfTokenForSession(sessionId);

        assertThat(secondTabToken).isEqualTo(firstTabToken);
        assertThat(store.hasValidCsrfToken(sessionId, firstTabToken)).isTrue();
    }

    @Test
    void enforcesIdleAndAbsoluteLifetimesAndExpiresTransactionsAtFiveMinutes() {
        MutableClock clock = new MutableClock(START);
        BoundedSessionStore store = new BoundedSessionStore(clock, new SecureRandom());
        String id = store.createSession(principal());
        var transaction = store.beginAuthorization();
        clock.advance(Duration.ofMinutes(29));
        assertThat(store.resolve(id)).isNotNull();
        clock.advance(Duration.ofMinutes(29));
        assertThat(store.resolve(id)).isNotNull();
        clock.advance(Duration.ofMinutes(2));
        assertThat(store.resolve(id)).isNull(); // Absolute expiry applies despite recent activity.
        String idleId = store.createSession(principal());
        clock.advance(Duration.ofMinutes(29));
        assertThat(store.resolve(idleId)).isNotNull();
        clock.advance(Duration.ofMinutes(30));
        assertThat(store.resolve(idleId)).isNull(); // Idle expiry is independent of absolute expiry.
        assertThatThrownBy(() -> store.claimAuthorization(transaction.state())).isInstanceOf(SecurityFailure.class);
        assertThat(store.cleanupExpired()).isZero();
    }

    @Test
    void concurrentPendingAdmissionsNeverExceedConfiguredCapacity() throws Exception {
        BoundedSessionStore store = new BoundedSessionStore(new MutableClock(START), new SecureRandom(), 10, 10);
        int attempts = 48;
        var ready = new CountDownLatch(12);
        var start = new CountDownLatch(1);
        var admitted = new AtomicInteger();
        var executor = Executors.newFixedThreadPool(12);
        try {
            for (int index = 0; index < attempts; index++) {
                executor.submit(() -> {
                    ready.countDown();
                    try {
                        start.await();
                        store.beginAuthorization();
                        admitted.incrementAndGet();
                    } catch (SecurityFailure expected) {
                        // Capacity is the expected result after the fixed bound is reached.
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                    }
                });
            }
            ready.await();
            start.countDown();
            executor.shutdown();
            assertThat(executor.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
        } finally {
            executor.shutdownNow();
        }
        assertThat(admitted.get()).isEqualTo(10);
        assertThat(store.pendingCount()).isEqualTo(10);
    }

    private static AuthenticatedPrincipal principal() {
        return new AuthenticatedPrincipal(new PrincipalIdentity("https://issuer.example", "subject-1"),
                "Operator", Set.of(), AuthenticationMechanism.SESSION);
    }

    private static void assertCapacity(Runnable operation) {
        assertThatThrownBy(operation::run).isInstanceOf(SecurityFailure.class)
                .extracting(failure -> ((SecurityFailure) failure).kind())
                .isEqualTo(SecurityFailure.Kind.CAPACITY_EXHAUSTED);
    }

    private static final class MutableClock extends Clock {
        private final AtomicReference<Instant> instant;

        private MutableClock(Instant value) { instant = new AtomicReference<>(value); }
        void advance(Duration duration) { instant.updateAndGet(current -> current.plus(duration)); }
        @Override public ZoneId getZone() { return ZoneId.of("UTC"); }
        @Override public Clock withZone(ZoneId zone) { return this; }
        @Override public Instant instant() { return instant.get(); }
    }
}
