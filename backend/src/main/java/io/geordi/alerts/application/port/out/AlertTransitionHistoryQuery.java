package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertEpisodeId;
import java.time.Duration;
import java.time.Instant;

public record AlertTransitionHistoryQuery(
        String policyId, AlertEpisodeId episodeId, Instant from, Instant to, int limit) {

    private static final int MAXIMUM_LIMIT = 200;
    private static final Duration MAXIMUM_RANGE = Duration.ofDays(31);

    public AlertTransitionHistoryQuery {
        policyId = optionalPolicyId(policyId);
        if ((from == null) != (to == null)) {
            throw new IllegalArgumentException("transition history range start and end must be supplied together");
        }
        if (from != null && (!from.isBefore(to) || Duration.between(from, to).compareTo(MAXIMUM_RANGE) > 0)) {
            throw new IllegalArgumentException("transition history range must be positive and no longer than 31 days");
        }
        if (policyId == null && episodeId == null && from == null) {
            throw new IllegalArgumentException("transition history query must be narrowed by policy, episode, or range");
        }
        if (limit <= 0 || limit > MAXIMUM_LIMIT) {
            throw new IllegalArgumentException("transition history limit must be between 1 and 200");
        }
    }

    private static String optionalPolicyId(String policyId) {
        if (policyId == null) {
            return null;
        }
        if (policyId.isBlank()) {
            throw new IllegalArgumentException("transition history policy id must not be blank");
        }
        return policyId;
    }
}
