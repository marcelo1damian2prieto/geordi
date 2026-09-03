package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertTransitionRecord;
import java.util.List;
import java.util.Objects;

/** A durable episode together with its immutable, episode-scoped transition records. */
public record AlertEpisodeDetail(AlertEpisode episode, List<AlertTransitionRecord> transitions) {

    public AlertEpisodeDetail {
        Objects.requireNonNull(episode, "episode must not be null");
        transitions = List.copyOf(Objects.requireNonNull(transitions, "transitions must not be null"));
    }
}
