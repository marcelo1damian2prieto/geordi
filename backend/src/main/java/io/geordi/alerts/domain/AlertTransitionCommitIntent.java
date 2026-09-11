package io.geordi.alerts.domain;

import java.util.Objects;

/** History and notification decision form one indivisible canonical transition intent. */
public record AlertTransitionCommitIntent(AlertHistoryMutation history, NotificationCommitIntent notification) {
    public AlertTransitionCommitIntent {
        Objects.requireNonNull(history, "history must not be null");
        Objects.requireNonNull(notification, "notification must not be null");
        if (notification instanceof NotificationCommitIntent.Matched matched
                && (!history.transition().equals(matched.delivery().transition())
                || !AlertTransitionId.from(history.transition()).value().equals(matched.delivery().id()))) {
            throw new IllegalArgumentException("history and delivery must identify the same canonical transition");
        }
    }

    public AlertNotificationDisposition disposition() {
        return new AlertNotificationDisposition(AlertTransitionId.from(history.transition()), notification.disposition());
    }
}
