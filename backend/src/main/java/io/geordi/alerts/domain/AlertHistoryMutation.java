package io.geordi.alerts.domain;

import java.util.Objects;

/**
 * Pure, unpersisted intent to apply one canonical transition to durable episode history.
 */
public sealed interface AlertHistoryMutation permits AlertHistoryMutation.Opened, AlertHistoryMutation.Resolved {

    AlertTransition transition();

    static AlertHistoryMutation from(AlertTransition transition) {
        Objects.requireNonNull(transition, "alert history transition must not be null");
        return switch (transition.type()) {
            case ALERT_STARTED -> new Opened(AlertEpisode.opened(transition.policyId(), transition.occurredAt()), transition);
            case ALERT_RESOLVED -> new Resolved(
                    transition, AlertEpisode.legacyResolved(transition.policyId(), transition.occurredAt()));
        };
    }

    record Opened(AlertEpisode episode, AlertTransition transition) implements AlertHistoryMutation {
        public Opened {
            Objects.requireNonNull(episode, "opened alert episode must not be null");
            Objects.requireNonNull(transition, "opened alert transition must not be null");
            if (transition.type() != AlertTransitionType.ALERT_STARTED
                    || episode.origin() != AlertEpisodeOrigin.M14
                    || !episode.open()
                    || !episode.policyId().equals(transition.policyId())
                    || !episode.openedAt().equals(transition.occurredAt())) {
                throw new IllegalArgumentException("opened alert history mutation must retain its canonical start");
            }
        }

        public AlertTransitionRecord record() {
            return AlertTransitionRecord.forEpisode(episode, transition);
        }
    }

    record Resolved(AlertTransition transition, AlertEpisode legacyEpisode) implements AlertHistoryMutation {
        public Resolved {
            Objects.requireNonNull(transition, "resolved alert transition must not be null");
            Objects.requireNonNull(legacyEpisode, "legacy resolved alert episode must not be null");
            if (transition.type() != AlertTransitionType.ALERT_RESOLVED
                    || legacyEpisode.origin() != AlertEpisodeOrigin.PRE_M14_UNKNOWN_START
                    || legacyEpisode.openedAt() != null
                    || !transition.policyId().equals(legacyEpisode.policyId())
                    || !transition.occurredAt().equals(legacyEpisode.closedAt())) {
                throw new IllegalArgumentException("resolved alert history mutation must retain its canonical resolution");
            }
        }

        public AlertTransitionRecord recordFor(AlertEpisode episode) {
            Objects.requireNonNull(episode, "resolved alert episode must not be null");
            if (!episode.policyId().equals(transition.policyId()) || episode.closedAt() == null
                    || !episode.closedAt().equals(transition.occurredAt())) {
                throw new IllegalArgumentException("resolved alert episode must match its canonical resolution");
            }
            return AlertTransitionRecord.forEpisode(episode, transition);
        }
    }
}
