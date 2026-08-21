package io.geordi.slos.application;

import io.geordi.slos.domain.SloEvaluation;

@FunctionalInterface
public interface SloEvaluationUseCase {

    SloEvaluation evaluate(String id);
}
