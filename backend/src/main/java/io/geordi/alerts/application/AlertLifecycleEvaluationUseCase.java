package io.geordi.alerts.application;

@FunctionalInterface
public interface AlertLifecycleEvaluationUseCase {

    AlertLifecycleEvaluationResult evaluate(String policyId);
}
