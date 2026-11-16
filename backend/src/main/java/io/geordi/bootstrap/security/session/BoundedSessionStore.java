package io.geordi.bootstrap.security.session;

import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

/** Restart-volatile browser sessions and one-use OIDC transactions with hard admission limits. */
public final class BoundedSessionStore {
    private static final int TOTAL_CAPACITY = 1024;
    private static final int PENDING_CAPACITY = 128;
    private static final Duration IDLE_LIMIT = Duration.ofMinutes(30);
    private static final Duration ABSOLUTE_LIMIT = Duration.ofHours(1);
    private static final Duration TRANSACTION_LIMIT = Duration.ofMinutes(5);

    private final Clock clock;
    private final SecureRandom random;
    private final int totalCapacity;
    private final int pendingCapacity;
    private final Map<String, StoredSession> sessions = new HashMap<>();
    private final Map<String, PendingEntry> pending = new HashMap<>();

    public BoundedSessionStore(Clock clock, SecureRandom random) {
        this(clock, random, TOTAL_CAPACITY, PENDING_CAPACITY);
    }

    BoundedSessionStore(Clock clock, SecureRandom random, int totalCapacity, int pendingCapacity) {
        this.clock = Objects.requireNonNull(clock);
        this.random = Objects.requireNonNull(random);
        if (totalCapacity < 1 || pendingCapacity < 1 || pendingCapacity > totalCapacity) {
            throw new IllegalArgumentException("invalid session capacity");
        }
        this.totalCapacity = totalCapacity;
        this.pendingCapacity = pendingCapacity;
    }

    public synchronized PendingAuthorization beginAuthorization() {
        return beginAuthorization(null);
    }

    public synchronized PendingAuthorization beginAuthorization(String priorSessionId) {
        evictExpired();
        if (pending.size() >= pendingCapacity || sessions.size() + pending.size() >= totalCapacity) {
            throw new SecurityFailure(SecurityFailure.Kind.CAPACITY_EXHAUSTED);
        }
        String state;
        do {
            state = randomValue();
        } while (pending.containsKey(state));
        PendingAuthorization transaction = new PendingAuthorization(
                state, randomValue(), randomValue(), clock.instant(), priorSessionId);
        pending.put(state, new PendingEntry(transaction));
        return transaction;
    }

    /** Atomically claims state once while keeping its admission slot reserved during token exchange. */
    public synchronized PendingAuthorization claimAuthorization(String state) {
        evictExpired();
        PendingEntry entry = state == null ? null : pending.get(state);
        if (entry == null || entry.claimed) throw SecurityFailure.invalid();
        entry.claimed = true;
        return entry.transaction;
    }

    /** Converts the claimed transaction's reserved slot into a session atomically. */
    public synchronized String completeAuthorization(String state, AuthenticatedPrincipal principal) {
        evictExpired();
        PendingEntry entry = state == null ? null : pending.get(state);
        if (entry == null || !entry.claimed) throw SecurityFailure.invalid();
        return createSession(principal, entry.transaction.priorSessionId, state);
    }

    /** Releases a failed callback's capacity reservation. */
    public synchronized void discardAuthorization(String state) {
        if (state != null) pending.remove(state);
    }

    /** Creates a fresh rotated cookie identifier after all protocol validation succeeds. */
    public synchronized String createSession(AuthenticatedPrincipal principal) {
        return createSession(principal, null);
    }

    /** Reauthentication invalidates the presented live identifier in the same admission transaction. */
    public synchronized String createSession(AuthenticatedPrincipal principal, String priorSessionId) {
        return createSession(principal, priorSessionId, null);
    }

    private String createSession(AuthenticatedPrincipal principal, String priorSessionId, String completingState) {
        evictExpired();
        if (principal == null || principal.mechanism() != AuthenticationMechanism.SESSION) {
            throw new IllegalArgumentException("browser session principal required");
        }
        StoredSession prior = priorSessionId == null ? null : sessions.get(priorSessionId);
        if (prior != null && expired(prior.createdAt, prior.lastActivityAt, clock.instant(), IDLE_LIMIT, ABSOLUTE_LIMIT)) {
            sessions.remove(priorSessionId);
            prior = null;
        }
        boolean replacingPending = completingState != null && pending.containsKey(completingState);
        if (sessions.size() + pending.size() >= totalCapacity && !replacingPending && prior == null) {
            throw new SecurityFailure(SecurityFailure.Kind.CAPACITY_EXHAUSTED);
        }
        String id;
        do {
            id = randomValue();
        } while (sessions.containsKey(id));
        Instant now = clock.instant();
        if (prior != null) sessions.remove(priorSessionId);
        if (completingState != null) pending.remove(completingState);
        sessions.put(id, new StoredSession(principal, now, randomValue()));
        return id;
    }

    /** Resolves and touches only a live session. Unknown and expired identifiers are equivalent. */
    public synchronized AuthenticatedPrincipal resolve(String id) {
        StoredSession session = liveSession(id, true);
        return session == null ? null : session.principal;
    }

    /** Checks a session for credential ambiguity without extending its idle lifetime. */
    public synchronized AuthenticatedPrincipal peek(String id) {
        StoredSession session = liveSession(id, false);
        return session == null ? null : session.principal;
    }

    private StoredSession liveSession(String id, boolean touch) {
        if (id == null) return null;
        StoredSession session = sessions.get(id);
        if (session == null) return null;
        Instant now = clock.instant();
        if (expired(session.createdAt, session.lastActivityAt, now, IDLE_LIMIT, ABSOLUTE_LIMIT)) {
            sessions.remove(id);
            return null;
        }
        if (touch) session.lastActivityAt = now;
        return session;
    }

    public synchronized String csrfTokenForSession(String id) {
        StoredSession session = liveSession(id, true);
        if (session == null) throw SecurityFailure.invalid();
        return session.csrfToken;
    }

    public synchronized boolean hasValidCsrfToken(String id, String candidate) {
        StoredSession session = liveSession(id, true);
        if (session == null || candidate == null) return false;
        return MessageDigest.isEqual(session.csrfToken.getBytes(StandardCharsets.US_ASCII),
                candidate.getBytes(StandardCharsets.US_ASCII));
    }

    public synchronized void logout(String id) {
        if (id != null) sessions.remove(id);
    }

    /** Called by the bounded cleanup task; returns the number of removed entries. */
    public synchronized int cleanupExpired() {
        int before = sessions.size() + pending.size();
        evictExpired();
        return before - sessions.size() - pending.size();
    }

    public synchronized int sessionCount() {
        evictExpired();
        return sessions.size();
    }

    public synchronized int pendingCount() {
        evictExpired();
        return pending.size();
    }

    private void evictExpired() {
        Instant now = clock.instant();
        sessions.entrySet().removeIf(entry -> expired(entry.getValue().createdAt, entry.getValue().lastActivityAt,
                now, IDLE_LIMIT, ABSOLUTE_LIMIT));
        pending.entrySet().removeIf(entry -> now.isBefore(entry.getValue().transaction.createdAt)
                || Duration.between(entry.getValue().transaction.createdAt, now).compareTo(TRANSACTION_LIMIT) >= 0);
    }

    private static boolean expired(Instant created, Instant last, Instant now, Duration idle, Duration absolute) {
        return now.isBefore(created) || now.isBefore(last)
                || Duration.between(last, now).compareTo(idle) >= 0
                || Duration.between(created, now).compareTo(absolute) >= 0;
    }

    private String randomValue() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    public static final class PendingAuthorization {
        private final String state;
        private final String nonce;
        private final String codeVerifier;
        private final Instant createdAt;
        private final String priorSessionId;

        private PendingAuthorization(String state, String nonce, String codeVerifier, Instant createdAt,
                String priorSessionId) {
            this.state = state;
            this.nonce = nonce;
            this.codeVerifier = codeVerifier;
            this.createdAt = createdAt;
            this.priorSessionId = priorSessionId;
        }

        public String state() { return state; }
        public String nonce() { return nonce; }
        public String codeVerifier() { return codeVerifier; }
        public String priorSessionId() { return priorSessionId; }

        @Override
        public String toString() {
            return "PendingAuthorization[redacted]";
        }
    }

    private static final class PendingEntry {
        private final PendingAuthorization transaction;
        private boolean claimed;

        private PendingEntry(PendingAuthorization transaction) {
            this.transaction = transaction;
        }
    }

    private static final class StoredSession {
        private final AuthenticatedPrincipal principal;
        private final Instant createdAt;
        private Instant lastActivityAt;
        private String csrfToken;

        private StoredSession(AuthenticatedPrincipal principal, Instant createdAt, String csrfToken) {
            this.principal = principal;
            this.createdAt = createdAt;
            this.lastActivityAt = createdAt;
            this.csrfToken = csrfToken;
        }
    }
}
