package io.geordi.alerts.application;

import java.util.Objects;

/** Credential-free scheduler entry over the same lifecycle coordinator as manual calls. */
public final class TrustedScheduledLifecycleEvaluationUseCase {
    private final AlertLifecycleEvaluationUseCase coordinator;

    public TrustedScheduledLifecycleEvaluationUseCase(AlertLifecycleEvaluationUseCase coordinator) {
        this.coordinator = Objects.requireNonNull(coordinator);
    }

    public AlertLifecycleEvaluationResult evaluate(String policyId) {
        return coordinator.evaluate(policyId);
    }
}
