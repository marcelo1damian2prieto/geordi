package io.geordi.alerts.domain;

import java.util.Objects;
import java.util.regex.Pattern;

/** A single ordered, terminal routing rule. */
public record AlertRoutingRule(
        String id,
        AlertRoutingPredicate predicate,
        AlertRoutingAction action,
        String destinationId) {

    private static final Pattern ID_PATTERN = Pattern.compile("[a-z0-9][a-z0-9-]{0,63}");

    public AlertRoutingRule {
        if (id == null || !ID_PATTERN.matcher(id).matches()) {
            throw new IllegalArgumentException("routing rule id must be a lowercase slug of at most 64 characters");
        }
        Objects.requireNonNull(predicate, "routing rule predicate must not be null");
        Objects.requireNonNull(action, "routing rule action must not be null");
        if (action == AlertRoutingAction.DELIVER) {
            if (destinationId == null || destinationId.isBlank()) {
                throw new IllegalArgumentException("deliver routing rule destination id is required");
            }
            destinationId = destinationId.trim();
            if (!ID_PATTERN.matcher(destinationId).matches()) {
                throw new IllegalArgumentException("routing destination id must be a lowercase slug of at most 64 characters");
            }
        } else if (destinationId != null) {
            throw new IllegalArgumentException("suppress routing rule must not specify a destination id");
        }
    }
}
