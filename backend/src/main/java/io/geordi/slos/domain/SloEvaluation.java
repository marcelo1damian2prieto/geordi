package io.geordi.slos.domain;

import java.math.BigDecimal;
import java.time.Instant;

public record SloEvaluation(
        String sloId,
        ServiceIdentity service,
        SliType sliType,
        BigDecimal target,
        EvaluationWindow window,
        TimeRange range,
        Instant evaluatedAt,
        BigDecimal observedValue,
        BigDecimal requestCount,
        SloStatus status,
        UnavailableReason reason,
        BurnRateEvaluation burnRateEvaluation) {
}
