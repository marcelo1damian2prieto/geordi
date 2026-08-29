package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.NotificationDeliveryWorkRepository;
import io.geordi.alerts.domain.NotificationDelivery;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Objects;

/**
 * Application boundary for dispatching already persisted notification work.
 */
public final class NotificationDeliveryWorkService {

    private final NotificationDeliveryWorkRepository repository;
    private final Clock clock;

    public NotificationDeliveryWorkService(NotificationDeliveryWorkRepository repository, Clock clock) {
        this.repository = Objects.requireNonNull(repository, "notification delivery repository must not be null");
        this.clock = Objects.requireNonNull(clock, "notification delivery clock must not be null");
    }

    public List<NotificationDelivery> claimDue(int limit, Duration leaseDuration, int maximumAttempts) {
        if (limit <= 0) {
            throw new IllegalArgumentException("notification claim limit must be positive");
        }
        if (leaseDuration == null || leaseDuration.isZero() || leaseDuration.isNegative()) {
            throw new IllegalArgumentException("notification lease duration must be positive");
        }
        if (maximumAttempts <= 0) {
            throw new IllegalArgumentException("notification maximum attempts must be positive");
        }
        Instant now = clock.instant();
        return repository.claimDue(now, now.plus(leaseDuration), limit, maximumAttempts);
    }

    public boolean markDelivered(NotificationDelivery delivery) {
        return repository.markDelivered(delivery.id(), claimToken(delivery), clock.instant());
    }

    public boolean retryOrFail(NotificationDelivery delivery, Instant nextAttemptAt, int maximumAttempts) {
        if (maximumAttempts <= 0) {
            throw new IllegalArgumentException("notification maximum attempts must be positive");
        }
        String token = claimToken(delivery);
        if (delivery.attempts() >= maximumAttempts) {
            return repository.markFailed(delivery.id(), token, clock.instant());
        }
        return repository.reschedule(
                delivery.id(), token, Objects.requireNonNull(nextAttemptAt, "notification retry time must not be null"));
    }

    public boolean markFailed(NotificationDelivery delivery) {
        return repository.markFailed(delivery.id(), claimToken(delivery), clock.instant());
    }

    private static String claimToken(NotificationDelivery delivery) {
        Objects.requireNonNull(delivery, "notification delivery must not be null");
        if (delivery.claimToken() == null) {
            throw new IllegalArgumentException("notification delivery must be claimed");
        }
        return delivery.claimToken();
    }
}
