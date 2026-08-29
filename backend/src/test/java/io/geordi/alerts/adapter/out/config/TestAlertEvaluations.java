package io.geordi.alerts.adapter.out.config;

import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;

final class TestAlertEvaluations {
    private TestAlertEvaluations() { }

    static AlertEvaluation met() {
        Instant now = Instant.parse("2026-08-28T12:00:00Z");
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE);
        return new AlertEvaluation("policy", "Policy", "slo", condition, AlertEvaluationStatus.CONDITION_MET,
                null, new BurnRateEvidence("slo", new ServiceIdentity("service", "namespace", "production"),
                EvaluationWindow.PT5M, new TimeRange(now.minusSeconds(300), now), now,
                BigDecimal.TEN, null));
    }
}
