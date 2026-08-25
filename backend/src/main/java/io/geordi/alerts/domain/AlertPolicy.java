package io.geordi.alerts.domain;

import java.util.Objects;
import java.util.regex.Pattern;

public record AlertPolicy(
        String id,
        String name,
        String description,
        boolean enabled,
        String sloId,
        AlertCondition condition) {

    private static final Pattern ID_PATTERN = Pattern.compile("[a-z0-9][a-z0-9-]{0,63}");

    public AlertPolicy {
        id = identifier(id, "alert policy id");
        name = required(name, "alert policy name", 120);
        description = optional(description, 500);
        sloId = identifier(sloId, "referenced SLO id");
        Objects.requireNonNull(condition, "alert condition must not be null");
    }

    private static String identifier(String value, String description) {
        if (value == null || !ID_PATTERN.matcher(value).matches()) {
            throw new IllegalArgumentException(description + " must be a lowercase slug of at most 64 characters");
        }
        return value;
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
            throw new IllegalArgumentException("alert policy description is too long");
        }
        return normalized;
    }
}
