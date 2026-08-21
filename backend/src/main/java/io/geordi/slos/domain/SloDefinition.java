package io.geordi.slos.domain;

import java.math.BigDecimal;
import java.util.Objects;
import java.util.regex.Pattern;

public record SloDefinition(
        String id,
        String name,
        String description,
        ServiceIdentity service,
        SliType sliType,
        BigDecimal target,
        EvaluationWindow window,
        boolean enabled) {

    private static final Pattern ID_PATTERN = Pattern.compile("[a-z0-9][a-z0-9-]{0,63}");

    public SloDefinition {
        if (id == null || !ID_PATTERN.matcher(id).matches()) {
            throw new IllegalArgumentException("SLO id must be a lowercase slug of at most 64 characters");
        }
        name = required(name, "SLO name", 120);
        description = optional(description, 500);
        Objects.requireNonNull(service, "SLO service must not be null");
        Objects.requireNonNull(sliType, "SLI type must not be null");
        Objects.requireNonNull(target, "SLO target must not be null");
        if (target.compareTo(BigDecimal.ZERO) < 0 || target.compareTo(BigDecimal.ONE) > 0) {
            throw new IllegalArgumentException("SLO target must be a ratio in [0,1]");
        }
        target = target.stripTrailingZeros();
        SliSemantics.requireJsonSafeTargetAndBurnRange(sliType, target);
        Objects.requireNonNull(window, "SLO window must not be null");
    }

    private static String required(String value, String description, int maximumLength) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
        String normalized = value.trim();
        if (normalized.length() > maximumLength) {
            throw new IllegalArgumentException(description + " is too long");
        }
        return normalized;
    }

    private static String optional(String value, int maximumLength) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String normalized = value.trim();
        if (normalized.length() > maximumLength) {
            throw new IllegalArgumentException("SLO description is too long");
        }
        return normalized;
    }
}
