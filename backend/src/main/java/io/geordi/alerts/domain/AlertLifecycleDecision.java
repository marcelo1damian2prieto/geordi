package io.geordi.alerts.domain;

import java.util.Objects;

public record AlertLifecycleDecision(
        AlertLifecycleProcessingOutcome outcome,
        AlertLifecycle current,
        AlertTransition transition,
        boolean writeRequired) {

    public AlertLifecycleDecision {
        Objects.requireNonNull(outcome, "lifecycle processing outcome must not be null");
        Objects.requireNonNull(current, "current lifecycle must not be null");
        if (outcome != AlertLifecycleProcessingOutcome.APPLIED && (transition != null || writeRequired)) {
            throw new IllegalArgumentException("ignored lifecycle evaluation must not write or transition");
        }
    }
}
