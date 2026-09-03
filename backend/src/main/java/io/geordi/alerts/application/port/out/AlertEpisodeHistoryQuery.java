package io.geordi.alerts.application.port.out;

import java.time.Duration;
import java.time.Instant;

public record AlertEpisodeHistoryQuery(
        String policyId, AlertEpisodeState state, Instant from, Instant to, int limit) {

    private static final int MAXIMUM_LIMIT = 100;
    private static final Duration MAXIMUM_RANGE = Duration.ofDays(31);

    public AlertEpisodeHistoryQuery {
        policyId = optionalPolicyId(policyId);
        if ((from == null) != (to == null)) {
            throw new IllegalArgumentException("episode history range start and end must be supplied together");
        }
        if (from != null && (!from.isBefore(to) || Duration.between(from, to).compareTo(MAXIMUM_RANGE) > 0)) {
            throw new IllegalArgumentException("episode history range must be positive and no longer than 31 days");
        }
        if (policyId == null && from == null) {
            throw new IllegalArgumentException("episode history query must be narrowed by policy or range");
        }
        if (limit <= 0 || limit > MAXIMUM_LIMIT) {
            throw new IllegalArgumentException("episode history limit must be between 1 and 100");
        }
    }

    private static String optionalPolicyId(String policyId) {
        if (policyId == null) {
            return null;
        }
        if (policyId.isBlank()) {
            throw new IllegalArgumentException("episode history policy id must not be blank");
        }
        return policyId;
    }
}
