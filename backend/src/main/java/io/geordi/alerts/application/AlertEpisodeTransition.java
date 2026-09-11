package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertTransitionRecord;
import java.util.Objects;

public record AlertEpisodeTransition(AlertTransitionRecord record, AlertNotificationStatus notification) {
    public AlertEpisodeTransition {
        Objects.requireNonNull(record);
        Objects.requireNonNull(notification);
    }
}
