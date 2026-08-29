package io.geordi.alerts.domain;

import java.util.Objects;

/**
 * Immutable, non-secret destination identity captured with a notification delivery.
 */
public record NotificationDestination(String id, String configurationFingerprint) {

    public NotificationDestination {
        requireText(id, "notification destination id must not be blank");
        requireText(configurationFingerprint, "notification destination fingerprint must not be blank");
    }

    private static void requireText(String value, String message) {
        if (Objects.requireNonNull(value, message).isBlank()) {
            throw new IllegalArgumentException(message);
        }
    }
}
