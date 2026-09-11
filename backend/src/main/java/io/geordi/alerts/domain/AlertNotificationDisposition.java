package io.geordi.alerts.domain;

import java.util.Objects;

/** Immutable notification decision for one canonical transition. */
public record AlertNotificationDisposition(AlertTransitionId transitionId, NotificationDisposition disposition) {
    public AlertNotificationDisposition {
        Objects.requireNonNull(transitionId, "transition id must not be null");
        Objects.requireNonNull(disposition, "notification disposition must not be null");
    }
}
