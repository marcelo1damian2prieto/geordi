package io.geordi.alerts.domain;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Objects;

/**
 * Durable, receiver-deduplicable work created from one canonical lifecycle transition.
 */
public record NotificationDelivery(
        String id,
        AlertTransition transition,
        NotificationDestination destination,
        NotificationDeliveryState state,
        int attempts,
        Instant createdAt,
        Instant nextAttemptAt,
        String claimToken,
        Instant leaseExpiresAt,
        Instant completedAt) {

    public NotificationDelivery {
        requireText(id, "notification delivery id must not be blank");
        Objects.requireNonNull(transition, "notification delivery transition must not be null");
        Objects.requireNonNull(destination, "notification delivery destination must not be null");
        Objects.requireNonNull(state, "notification delivery state must not be null");
        Objects.requireNonNull(createdAt, "notification delivery creation time must not be null");
        Objects.requireNonNull(nextAttemptAt, "notification delivery next attempt time must not be null");
        if (attempts < 0) {
            throw new IllegalArgumentException("notification delivery attempts must not be negative");
        }
        validateState(state, claimToken, leaseExpiresAt, completedAt);
    }

    public static NotificationDelivery pending(
            AlertTransition transition, NotificationDestination destination, Instant createdAt) {
        Objects.requireNonNull(createdAt, "notification delivery creation time must not be null");
        return new NotificationDelivery(
                stableId(transition), transition, destination, NotificationDeliveryState.PENDING, 0,
                createdAt, createdAt, null, null, null);
    }

    public static String stableId(AlertTransition transition) {
        Objects.requireNonNull(transition, "notification transition must not be null");
        String identity = transition.policyId() + "\n" + transition.type().name() + "\n" + transition.occurredAt();
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(identity.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available", exception);
        }
    }

    public NotificationDelivery leased(String token, Instant expiresAt) {
        if (state == NotificationDeliveryState.DELIVERED || state == NotificationDeliveryState.FAILED) {
            throw new IllegalStateException("terminal notification delivery cannot be leased");
        }
        requireText(token, "notification delivery claim token must not be blank");
        Objects.requireNonNull(expiresAt, "notification delivery lease expiry must not be null");
        return new NotificationDelivery(
                id, transition, destination, NotificationDeliveryState.LEASED, attempts + 1, createdAt, nextAttemptAt,
                token, expiresAt, null);
    }

    public NotificationDelivery delivered(Instant completedAt) {
        return complete(NotificationDeliveryState.DELIVERED, completedAt);
    }

    public NotificationDelivery pendingRetry(Instant nextAttemptAt) {
        Objects.requireNonNull(nextAttemptAt, "notification retry time must not be null");
        requireLease();
        return new NotificationDelivery(
                id, transition, destination, NotificationDeliveryState.PENDING, attempts, createdAt,
                nextAttemptAt, null, null, null);
    }

    public NotificationDelivery failed(Instant completedAt) {
        return complete(NotificationDeliveryState.FAILED, completedAt);
    }

    private NotificationDelivery complete(NotificationDeliveryState target, Instant completedAt) {
        requireLease();
        Objects.requireNonNull(completedAt, "notification delivery completion time must not be null");
        return new NotificationDelivery(
                id, transition, destination, target, attempts, createdAt, nextAttemptAt,
                null, null, completedAt);
    }

    private void requireLease() {
        if (state != NotificationDeliveryState.LEASED || claimToken == null) {
            throw new IllegalStateException("notification delivery must be leased before completion");
        }
    }

    private static void validateState(
            NotificationDeliveryState state, String claimToken, Instant leaseExpiresAt, Instant completedAt) {
        boolean claimed = claimToken != null || leaseExpiresAt != null;
        if ((claimToken == null) != (leaseExpiresAt == null)) {
            throw new IllegalArgumentException("notification delivery lease must be complete");
        }
        if (state == NotificationDeliveryState.LEASED && !claimed) {
            throw new IllegalArgumentException("leased notification delivery must have a lease");
        }
        if (state != NotificationDeliveryState.LEASED && claimed) {
            throw new IllegalArgumentException("only leased notification delivery may retain a lease");
        }
        if ((state == NotificationDeliveryState.DELIVERED || state == NotificationDeliveryState.FAILED)
                != (completedAt != null)) {
            throw new IllegalArgumentException("terminal notification delivery must have a completion time");
        }
    }

    private static void requireText(String value, String message) {
        if (Objects.requireNonNull(value, message).isBlank()) {
            throw new IllegalArgumentException(message);
        }
    }
}
