package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.NotificationDelivery;
import java.time.Instant;
import java.util.List;

/**
 * Durable work queue for already committed notification deliveries.
 */
public interface NotificationDeliveryWorkRepository {

    List<NotificationDelivery> claimDue(Instant now, Instant leaseExpiresAt, int limit, int maximumAttempts);

    boolean markDelivered(String deliveryId, String claimToken, Instant completedAt);

    boolean reschedule(String deliveryId, String claimToken, Instant nextAttemptAt);

    boolean markFailed(String deliveryId, String claimToken, Instant completedAt);
}
