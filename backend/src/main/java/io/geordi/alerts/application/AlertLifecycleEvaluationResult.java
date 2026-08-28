package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleProcessingOutcome;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertTransition;
import java.util.Objects;

public record AlertLifecycleEvaluationResult(
        AlertPolicy policy,
        AlertEvaluation triggeringEvaluation,
        AlertLifecycleProcessingOutcome outcome,
        AlertLifecycle current,
        AlertTransition transition) {

    public AlertLifecycleEvaluationResult {
        Objects.requireNonNull(policy, "lifecycle policy must not be null");
        Objects.requireNonNull(triggeringEvaluation, "triggering evaluation must not be null");
        Objects.requireNonNull(outcome, "processing outcome must not be null");
        Objects.requireNonNull(current, "current lifecycle must not be null");
    }
}
