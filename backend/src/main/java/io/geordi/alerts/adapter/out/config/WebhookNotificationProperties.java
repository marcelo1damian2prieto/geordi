package io.geordi.alerts.adapter.out.config;

import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.notification", ignoreUnknownFields = false)
public record WebhookNotificationProperties(
        boolean enabled,
        String destinationId,
        URI endpoint,
        String token,
        String tokenHeader,
        List<String> transitions,
        Duration connectTimeout,
        Duration readTimeout,
        Duration pollInterval,
        Duration leaseDuration,
        int batchSize,
        int maximumAttempts,
        boolean allowInsecureLocalHttp) {

    private static final Pattern HEADER_NAME = Pattern.compile("[!#$%&'*+.^_`|~0-9A-Za-z-]+");
    private static final Set<String> RESERVED_HEADERS = Set.of(
            "connection", "content-length", "content-type", "expect", "host", "idempotency-key", "upgrade");

    public WebhookNotificationProperties {
        transitions = transitions == null ? List.of() : List.copyOf(transitions);
        if (enabled) {
            requireText(destinationId, "notification destination id is required");
            requireText(token, "notification token is required");
            requireText(tokenHeader, "notification token header is required");
            if (!HEADER_NAME.matcher(tokenHeader).matches()
                    || RESERVED_HEADERS.contains(tokenHeader.toLowerCase(java.util.Locale.ROOT))) {
                throw new IllegalArgumentException("notification token header is invalid");
            }
            if (endpoint == null || endpoint.getUserInfo() != null || endpoint.getHost() == null) {
                throw new IllegalArgumentException("notification endpoint is invalid");
            }
            boolean secure = "https".equalsIgnoreCase(endpoint.getScheme());
            boolean localTest = allowInsecureLocalHttp && "http".equalsIgnoreCase(endpoint.getScheme())
                    && ("webhook-receiver".equalsIgnoreCase(endpoint.getHost())
                    || "localhost".equalsIgnoreCase(endpoint.getHost()));
            if (!secure && !localTest) {
                throw new IllegalArgumentException("notification endpoint must use HTTPS");
            }
            if (transitions.isEmpty() || transitions.stream().anyMatch(value ->
                    !"ALERT_STARTED".equals(value) && !"ALERT_RESOLVED".equals(value))) {
                throw new IllegalArgumentException("notification transitions are invalid");
            }
            requirePositive(connectTimeout, "notification connect timeout");
            requirePositive(readTimeout, "notification read timeout");
            requirePositive(pollInterval, "notification poll interval");
            requirePositive(leaseDuration, "notification lease duration");
            if (readTimeout.compareTo(leaseDuration) >= 0) {
                throw new IllegalArgumentException("notification read timeout must be shorter than lease duration");
            }
            if (batchSize < 1 || batchSize > 100 || maximumAttempts < 1 || maximumAttempts > 10) {
                throw new IllegalArgumentException("notification worker bounds are invalid");
            }
        }
    }

    private static void requireText(String value, String message) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(message);
        }
    }

    private static void requirePositive(Duration value, String label) {
        if (value == null || value.isZero() || value.isNegative()) {
            throw new IllegalArgumentException(label + " must be positive");
        }
    }
}
