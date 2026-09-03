package io.geordi.alerts.domain;

import java.util.Objects;

/**
 * Immutable durable copy of the canonical lifecycle transition, linked to its episode.
 */
public record AlertTransitionRecord(AlertTransitionId id, AlertEpisodeId episodeId, AlertTransition transition) {

    public AlertTransitionRecord {
        Objects.requireNonNull(id, "alert transition record id must not be null");
        Objects.requireNonNull(episodeId, "alert transition record episode id must not be null");
        Objects.requireNonNull(transition, "alert transition record transition must not be null");
        if (!id.equals(AlertTransitionId.from(transition))) {
            throw new IllegalArgumentException("alert transition record id must match its canonical transition");
        }
    }

    public static AlertTransitionRecord forEpisode(AlertEpisode episode, AlertTransition transition) {
        Objects.requireNonNull(episode, "alert transition record episode must not be null");
        Objects.requireNonNull(transition, "alert transition record transition must not be null");
        if (!episode.policyId().equals(transition.policyId())) {
            throw new IllegalArgumentException("alert transition record and episode policy ids must match");
        }
        return new AlertTransitionRecord(AlertTransitionId.from(transition), episode.id(), transition);
    }
}
