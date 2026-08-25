package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertEvaluation;

@FunctionalInterface
public interface AlertEvaluationUseCase {

    AlertEvaluation evaluate(String policyId);
}
