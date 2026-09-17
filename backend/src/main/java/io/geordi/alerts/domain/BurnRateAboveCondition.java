package io.geordi.alerts.domain;

import java.math.BigDecimal;

public record BurnRateAboveCondition(BigDecimal threshold) implements AlertCondition {

    public BurnRateAboveCondition {
        threshold = BurnRateThreshold.normalize(threshold, "alert threshold");
    }

    @Override
    public AlertConditionType type() {
        return AlertConditionType.BURN_RATE_ABOVE;
    }
}
