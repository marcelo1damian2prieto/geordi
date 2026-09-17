package io.geordi.slos.application;

import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.SliSemantics;
import io.geordi.slos.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Duration;
import java.util.Objects;

public record WindowedBurnRateObservation(
        Duration observationWindow,
        TimeRange range,
        BigDecimal observedBurnRate,
        BurnRateUnavailableReason reason) {

    public WindowedBurnRateObservation {
        Objects.requireNonNull(observationWindow, "observation window must not be null");
        Objects.requireNonNull(range, "observation range must not be null");
        if ((observedBurnRate == null) == (reason == null)) {
            throw new IllegalArgumentException("observation requires a burn rate or unavailable reason");
        }
        if (observedBurnRate != null) {
            if (observedBurnRate.signum() < 0 || !SliSemantics.isJsonSafeNumber(observedBurnRate)) {
                throw new IllegalArgumentException("observed burn rate must be finite and non-negative");
            }
            observedBurnRate = observedBurnRate.stripTrailingZeros();
        }
    }

    public static WindowedBurnRateObservation available(
            Duration observationWindow, TimeRange range, BigDecimal observedBurnRate) {
        return new WindowedBurnRateObservation(observationWindow, range, observedBurnRate, null);
    }

    public static WindowedBurnRateObservation unavailable(
            Duration observationWindow, TimeRange range, BurnRateUnavailableReason reason) {
        return new WindowedBurnRateObservation(observationWindow, range, null, reason);
    }
}
