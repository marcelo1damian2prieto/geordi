package io.geordi.alerts.adapter.out.config;

import io.geordi.alerts.application.port.out.NotificationDestinationSelector;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.NotificationDestination;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Optional;

public final class ConfigurationNotificationDestinationSelector implements NotificationDestinationSelector {

    private final WebhookNotificationProperties properties;
    private final NotificationDestination destination;

    public ConfigurationNotificationDestinationSelector(WebhookNotificationProperties properties) {
        this.properties = properties;
        this.destination = properties.enabled()
                ? new NotificationDestination(properties.destinationId(), fingerprint(properties)) : null;
    }

    @Override
    public Optional<NotificationDestination> selectFor(AlertTransition transition) {
        return properties.enabled() && properties.transitions().contains(transition.type().name())
                ? Optional.of(destination) : Optional.empty();
    }

    private static String fingerprint(WebhookNotificationProperties properties) {
        String value = properties.destinationId() + "\n" + properties.endpoint().normalize()
                + "\n" + properties.tokenHeader().toLowerCase(java.util.Locale.ROOT);
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available", exception);
        }
    }
}
