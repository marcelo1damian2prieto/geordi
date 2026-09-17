package io.geordi.alerts.domain;

import java.math.BigDecimal;
import java.util.Objects;

final class BurnRateThreshold {

    private BurnRateThreshold() {
    }

    static BigDecimal normalize(BigDecimal threshold, String description) {
        Objects.requireNonNull(threshold, description + " must not be null");
        if (threshold.signum() < 0) {
            throw new IllegalArgumentException(description + " must not be negative");
        }
        BigDecimal normalized = threshold.stripTrailingZeros();
        double publicValue = normalized.doubleValue();
        if (!Double.isFinite(publicValue) || normalized.signum() > 0 && publicValue == 0) {
            throw new IllegalArgumentException(description + " must be a finite public number");
        }
        return normalized;
    }
}
