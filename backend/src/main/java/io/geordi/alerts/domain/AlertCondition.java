package io.geordi.alerts.domain;

import java.math.BigDecimal;
import java.util.Objects;

public record AlertCondition(AlertConditionType type, BigDecimal threshold) {

    public AlertCondition {
        Objects.requireNonNull(type, "alert condition type must not be null");
        Objects.requireNonNull(threshold, "alert threshold must not be null");
        if (threshold.signum() < 0) {
            throw new IllegalArgumentException("alert threshold must not be negative");
        }
        threshold = threshold.stripTrailingZeros();
        double publicValue = threshold.doubleValue();
        if (!Double.isFinite(publicValue) || threshold.signum() > 0 && publicValue == 0) {
            throw new IllegalArgumentException("alert threshold must be a finite public number");
        }
    }
}
