package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;

/**
 * A durable firing interval. Legacy episodes intentionally retain an unknown opening time.
 */
public record AlertEpisode(
        AlertEpisodeId id,
        String policyId,
        Instant openedAt,
        Instant closedAt,
        AlertEpisodeOrigin origin) {

    public AlertEpisode {
        Objects.requireNonNull(id, "alert episode id must not be null");
        requirePolicyId(policyId);
        Objects.requireNonNull(origin, "alert episode origin must not be null");
        if (origin == AlertEpisodeOrigin.M14 && openedAt == null) {
            throw new IllegalArgumentException("M14 alert episode must have an opening time");
        }
        if (origin == AlertEpisodeOrigin.PRE_M14_UNKNOWN_START && openedAt != null) {
            throw new IllegalArgumentException("legacy alert episode must retain an unknown opening time");
        }
        if (openedAt != null && closedAt != null && closedAt.isBefore(openedAt)) {
            throw new IllegalArgumentException("alert episode cannot close before it opens");
        }
    }

    public static AlertEpisode opened(String policyId, Instant openedAt) {
        return new AlertEpisode(AlertEpisodeId.opened(policyId, openedAt), policyId, openedAt, null, AlertEpisodeOrigin.M14);
    }

    public static AlertEpisode legacyResolved(String policyId, Instant resolvedAt) {
        return new AlertEpisode(
                AlertEpisodeId.legacyResolved(policyId, resolvedAt), policyId, null, resolvedAt,
                AlertEpisodeOrigin.PRE_M14_UNKNOWN_START);
    }

    public AlertEpisode resolve(Instant resolvedAt) {
        Objects.requireNonNull(resolvedAt, "alert episode resolution time must not be null");
        if (closedAt != null) {
            throw new IllegalStateException("closed alert episode cannot be resolved again");
        }
        return new AlertEpisode(id, policyId, openedAt, resolvedAt, origin);
    }

    public boolean open() {
        return closedAt == null;
    }

    private static void requirePolicyId(String policyId) {
        if (Objects.requireNonNull(policyId, "alert episode policy id must not be null").isBlank()) {
            throw new IllegalArgumentException("alert episode policy id must not be blank");
        }
    }
}
