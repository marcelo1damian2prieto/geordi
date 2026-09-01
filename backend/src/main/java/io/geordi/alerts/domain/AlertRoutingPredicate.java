package io.geordi.alerts.domain;

import java.util.Objects;

/**
 * Bounded exact-match criteria for an alert transition. A null criterion is a wildcard.
 */
public record AlertRoutingPredicate(
        String policyId,
        String serviceNamespace,
        String serviceName,
        String environment,
        AlertTransitionType transitionType) {

    private static final int MAXIMUM_VALUE_LENGTH = 255;

    public AlertRoutingPredicate {
        policyId = optional(policyId, "routing policy id");
        serviceNamespace = optional(serviceNamespace, "routing service namespace");
        serviceName = optional(serviceName, "routing service name");
        environment = optional(environment, "routing environment");
    }

    public boolean matches(AlertTransition transition) {
        Objects.requireNonNull(transition, "routing transition must not be null");
        ServiceIdentity service = transition.evaluation().evidence().service();
        return matches(policyId, transition.policyId())
                && matches(serviceNamespace, service.namespace())
                && matches(serviceName, service.name())
                && matches(environment, service.environment())
                && (transitionType == null || transitionType == transition.type());
    }

    private static String optional(String value, String label) {
        if (value == null) {
            return null;
        }
        if (value.isBlank()) {
            throw new IllegalArgumentException(label + " must be omitted or non-blank");
        }
        String normalized = value.trim();
        if (normalized.length() > MAXIMUM_VALUE_LENGTH) {
            throw new IllegalArgumentException(label + " is too long");
        }
        return normalized;
    }

    private static boolean matches(String criterion, String actual) {
        return criterion == null || criterion.equals(actual);
    }
}
