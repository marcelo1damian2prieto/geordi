package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;

public record AlertTransition(
        String policyId,
        AlertTransitionType type,
        AlertLifecycleState previousState,
        AlertLifecycleState currentState,
        Instant occurredAt,
        AlertEvaluation evaluation) {

    public AlertTransition {
        Objects.requireNonNull(policyId, "transition policy id must not be null");
        Objects.requireNonNull(type, "transition type must not be null");
        Objects.requireNonNull(previousState, "transition previous state must not be null");
        Objects.requireNonNull(currentState, "transition current state must not be null");
        Objects.requireNonNull(occurredAt, "transition time must not be null");
        Objects.requireNonNull(evaluation, "transition evaluation must not be null");
        if (!policyId.equals(evaluation.policyId())) {
            throw new IllegalArgumentException("transition and evaluation policy ids must match");
        }
        boolean started = type == AlertTransitionType.ALERT_STARTED
                && previousState == AlertLifecycleState.INACTIVE
                && currentState == AlertLifecycleState.FIRING
                && evaluation.status() == AlertEvaluationStatus.CONDITION_MET;
        boolean resolved = type == AlertTransitionType.ALERT_RESOLVED
                && previousState == AlertLifecycleState.FIRING
                && currentState == AlertLifecycleState.INACTIVE
                && evaluation.status() == AlertEvaluationStatus.CONDITION_NOT_MET;
        if (!started && !resolved) {
            throw new IllegalArgumentException("transition type, states, and evaluation must be coherent");
        }
    }
}
