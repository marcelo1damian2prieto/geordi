package io.geordi.slos.domain;

import java.math.BigDecimal;
import java.util.Objects;

public record BurnRateEvaluation(
        BigDecimal allowedBadRatio,
        BigDecimal observedBadRatio,
        BigDecimal burnRate,
        BurnRateStatus status,
        BurnRateUnavailableReason reason) {

    public BurnRateEvaluation {
        allowedBadRatio = ratio(allowedBadRatio, "allowed bad ratio");
        if (observedBadRatio != null) {
            observedBadRatio = ratio(observedBadRatio, "observed bad ratio");
        }
        if (burnRate != null) {
            if (burnRate.signum() < 0) {
                throw new IllegalArgumentException("burn rate must not be negative");
            }
            burnRate = burnRate.stripTrailingZeros();
            jsonSafe(burnRate, "burn rate");
        }
        Objects.requireNonNull(status, "burn-rate status must not be null");
        if (status == BurnRateStatus.AVAILABLE) {
            if (allowedBadRatio.signum() == 0 || observedBadRatio == null || burnRate == null || reason != null) {
                throw new IllegalArgumentException("available burn rate requires valid ratios and no reason");
            }
        } else if (burnRate != null || reason == null) {
            throw new IllegalArgumentException("unavailable burn rate requires no value and a reason");
        }
        if (reason == BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO) {
            if (allowedBadRatio.signum() != 0 || observedBadRatio == null) {
                throw new IllegalArgumentException("zero-budget unavailability requires an observed bad ratio");
            }
        } else if (status == BurnRateStatus.UNAVAILABLE && observedBadRatio != null) {
            throw new IllegalArgumentException("unavailable telemetry must not have an observed bad ratio");
        }
    }

    public static BurnRateEvaluation available(
            BigDecimal allowedBadRatio, BigDecimal observedBadRatio, BigDecimal burnRate) {
        return new BurnRateEvaluation(
                allowedBadRatio, observedBadRatio, burnRate, BurnRateStatus.AVAILABLE, null);
    }

    public static BurnRateEvaluation unavailable(
            BigDecimal allowedBadRatio, BurnRateUnavailableReason reason) {
        return new BurnRateEvaluation(
                allowedBadRatio, null, null, BurnRateStatus.UNAVAILABLE, reason);
    }

    public static BurnRateEvaluation unavailableWithObservedBadRatio(
            BigDecimal allowedBadRatio,
            BigDecimal observedBadRatio,
            BurnRateUnavailableReason reason) {
        return new BurnRateEvaluation(
                allowedBadRatio, observedBadRatio, null, BurnRateStatus.UNAVAILABLE, reason);
    }

    private static BigDecimal ratio(BigDecimal value, String description) {
        Objects.requireNonNull(value, description + " must not be null");
        if (value.compareTo(BigDecimal.ZERO) < 0 || value.compareTo(BigDecimal.ONE) > 0) {
            throw new IllegalArgumentException(description + " must be in [0,1]");
        }
        BigDecimal normalized = value.stripTrailingZeros();
        jsonSafe(normalized, description);
        return normalized;
    }

    private static void jsonSafe(BigDecimal value, String description) {
        if (!SliSemantics.isJsonSafeNumber(value)) {
            throw new IllegalArgumentException(description + " must be representable as a JavaScript number");
        }
    }
}
