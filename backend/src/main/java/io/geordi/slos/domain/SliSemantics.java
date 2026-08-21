package io.geordi.slos.domain;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.util.Objects;

public final class SliSemantics {

    private static final int DERIVED_VALUE_PRECISION = 12;
    private static final MathContext DERIVED_VALUE_CONTEXT =
            new MathContext(DERIVED_VALUE_PRECISION, RoundingMode.HALF_UP);
    private static final BigDecimal MAXIMUM_JSON_NUMBER = BigDecimal.valueOf(Double.MAX_VALUE);

    private SliSemantics() {
    }

    public static BigDecimal allowedBadRatio(SliType type, BigDecimal target) {
        Objects.requireNonNull(type, "SLI type must not be null");
        Objects.requireNonNull(target, "SLO target must not be null");
        return switch (type) {
            case AVAILABILITY -> BigDecimal.ONE.subtract(target).stripTrailingZeros();
            case ERROR_RATE -> target.stripTrailingZeros();
        };
    }

    public static void requireJsonSafeTargetAndBurnRange(SliType type, BigDecimal target) {
        if (!isJsonSafeNumber(target)) {
            throw new IllegalArgumentException("SLO target must be representable as a JavaScript number");
        }
        double targetNumber = target.doubleValue();
        if (target.compareTo(BigDecimal.ZERO) > 0 && target.compareTo(BigDecimal.ONE) < 0
                && (targetNumber == 0d || targetNumber == 1d)) {
            throw new IllegalArgumentException("SLO target must remain distinct from zero and one in JSON");
        }
        BigDecimal allowedBadRatio = allowedBadRatio(type, target);
        if (allowedBadRatio.signum() > 0
                && allowedBadRatio.multiply(MAXIMUM_JSON_NUMBER).compareTo(BigDecimal.ONE) < 0) {
            throw new IllegalArgumentException(
                    "nonzero allowed bad ratio must permit a JavaScript-safe burn rate");
        }
    }

    public static BigDecimal observedValue(
            SliType type, BigDecimal requestCount, BigDecimal errorCount) {
        Objects.requireNonNull(type, "SLI type must not be null");
        BigDecimal numerator = switch (type) {
            case AVAILABILITY -> requestCount.subtract(errorCount);
            case ERROR_RATE -> errorCount;
        };
        return divide(numerator, requestCount);
    }

    public static BigDecimal observedBadRatio(BigDecimal requestCount, BigDecimal errorCount) {
        return divide(errorCount, requestCount);
    }

    public static boolean meetsTarget(
            SliType type, BigDecimal target, BigDecimal requestCount, BigDecimal errorCount) {
        Objects.requireNonNull(type, "SLI type must not be null");
        BigDecimal numerator = switch (type) {
            case AVAILABILITY -> requestCount.subtract(errorCount);
            case ERROR_RATE -> errorCount;
        };
        int exactComparison = numerator.compareTo(target.multiply(requestCount));
        return type == SliType.AVAILABILITY ? exactComparison >= 0 : exactComparison <= 0;
    }

    public static BigDecimal burnRate(
            BigDecimal requestCount, BigDecimal errorCount, BigDecimal allowedBadRatio) {
        return errorCount.divide(requestCount.multiply(allowedBadRatio), DERIVED_VALUE_CONTEXT)
                .stripTrailingZeros();
    }

    public static boolean isJsonSafeNumber(BigDecimal value) {
        double converted = value.doubleValue();
        return Double.isFinite(converted) && (value.signum() == 0 || converted != 0d);
    }

    private static BigDecimal divide(BigDecimal numerator, BigDecimal denominator) {
        return numerator.divide(denominator, DERIVED_VALUE_CONTEXT).stripTrailingZeros();
    }
}
