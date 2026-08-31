package io.geordi.alerts.application;

import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public final class SingleFlightAlertLifecycleEvaluationUseCase implements AlertLifecycleEvaluationUseCase {
    private final AlertLifecycleEvaluationUseCase delegate;
    private final Set<String> activePolicyIds = ConcurrentHashMap.newKeySet();

    public SingleFlightAlertLifecycleEvaluationUseCase(AlertLifecycleEvaluationUseCase delegate) {
        this.delegate = Objects.requireNonNull(delegate, "lifecycle evaluation delegate must not be null");
    }

    @Override
    public AlertLifecycleEvaluationResult evaluate(String policyId) {
        if (!activePolicyIds.add(policyId)) {
            throw new AlertLifecycleEvaluationInProgressException();
        }
        try {
            return delegate.evaluate(policyId);
        } finally {
            activePolicyIds.remove(policyId);
        }
    }
}
