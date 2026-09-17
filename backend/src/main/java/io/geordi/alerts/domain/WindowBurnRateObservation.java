package io.geordi.alerts.domain;

import java.math.BigDecimal;
import java.util.Objects;

public record WindowBurnRateObservation(
        AlertObservationWindow observationWindow,
        TimeRange range,
        BigDecimal observedBurnRate,
        AlertUnavailableReason reason) {

    public WindowBurnRateObservation {
        Objects.requireNonNull(observationWindow, "alert observation window must not be null");
        Objects.requireNonNull(range, "alert observation range must not be null");
        if (!range.from().plus(observationWindow.duration()).equals(range.to())) {
            throw new IllegalArgumentException("alert observation range must match its canonical window");
        }
        if (observedBurnRate != null) {
            observedBurnRate = BurnRateThreshold.normalize(observedBurnRate, "observed burn rate");
        }
        if ((observedBurnRate == null) == (reason == null)) {
            throw new IllegalArgumentException(
                    "alert observation requires exactly one of burn rate or unavailable reason");
        }
        if (reason == AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE) {
            throw new IllegalArgumentException("aggregate unavailable reason cannot be used by one observation");
        }
    }

    public boolean available() {
        return observedBurnRate != null;
    }
}
