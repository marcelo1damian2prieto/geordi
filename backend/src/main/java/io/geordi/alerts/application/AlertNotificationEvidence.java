package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionId;
import io.geordi.alerts.domain.NotificationDeliveryState;
import io.geordi.alerts.domain.NotificationDisposition;
import java.time.Instant;

/** Internal evidence without destination, payload text, or ownership secrets. Nulls preserve row absence. */
public record AlertNotificationEvidence(
        AlertTransitionId transitionId, NotificationDisposition disposition, Delivery delivery) {
    public record Delivery(String id, AlertTransition transition, NotificationDeliveryState state,
            int attempts, Instant createdAt, Instant nextAttemptAt, Instant completedAt) { }
}
