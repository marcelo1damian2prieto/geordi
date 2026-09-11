package io.geordi.alerts.domain;

import java.util.Objects;

/** Closed notification work: only matched decisions can contain a delivery. */
public sealed interface NotificationCommitIntent {
    NotificationDisposition disposition();

    record Matched(NotificationDelivery delivery) implements NotificationCommitIntent {
        public Matched {
            Objects.requireNonNull(delivery, "matched delivery must not be null");
        }

        @Override
        public NotificationDisposition disposition() { return NotificationDisposition.MATCHED; }
    }

    enum Suppressed implements NotificationCommitIntent {
        INSTANCE;
        @Override
        public NotificationDisposition disposition() { return NotificationDisposition.SUPPRESSED; }
    }

    enum Unrouted implements NotificationCommitIntent {
        INSTANCE;
        @Override
        public NotificationDisposition disposition() { return NotificationDisposition.UNROUTED; }
    }
}
