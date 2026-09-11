package io.geordi.alerts.application;

import io.geordi.alerts.domain.NotificationDeliveryState;
import java.time.Instant;

/** Safe detail-only projection. NOT_RECORDED is absence of a durable disposition fact. */
public record AlertNotificationStatus(Disposition disposition, Delivery delivery) {
    public enum Disposition { MATCHED, SUPPRESSED, UNROUTED, NOT_RECORDED }

    public record Delivery(NotificationDeliveryState state, int attempts,
            Instant createdAt, Instant nextAttemptAt, Instant completedAt) { }
}
