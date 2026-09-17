package io.geordi.alerts.domain;

import java.util.Objects;

public record BurnRateBandResult(
        BurnRateBand band,
        WindowBurnRateObservation longObservation,
        WindowBurnRateObservation shortObservation,
        BurnRateBandOutcome outcome) {

    public BurnRateBandResult {
        Objects.requireNonNull(band, "burn-rate band result band must not be null");
        Objects.requireNonNull(longObservation, "burn-rate band result long observation must not be null");
        Objects.requireNonNull(shortObservation, "burn-rate band result short observation must not be null");
        Objects.requireNonNull(outcome, "burn-rate band result outcome must not be null");
        if (longObservation.observationWindow() != band.longWindow()
                || shortObservation.observationWindow() != band.shortWindow()
                || outcome != outcome(longObservation, shortObservation, band)) {
            throw new IllegalArgumentException("burn-rate band result must match its canonical observations");
        }
    }

    public static BurnRateBandResult evaluate(BurnRateBand band, MultiwindowBurnRateEvidence evidence) {
        Objects.requireNonNull(band, "burn-rate band must not be null");
        Objects.requireNonNull(evidence, "multiwindow evidence must not be null");
        WindowBurnRateObservation longObservation = evidence.observation(band.longWindow());
        WindowBurnRateObservation shortObservation = evidence.observation(band.shortWindow());
        return new BurnRateBandResult(
                band, longObservation, shortObservation, outcome(longObservation, shortObservation, band));
    }

    private static BurnRateBandOutcome outcome(
            WindowBurnRateObservation longObservation,
            WindowBurnRateObservation shortObservation,
            BurnRateBand band) {
        if (belowThreshold(longObservation, band) || belowThreshold(shortObservation, band)) {
            return BurnRateBandOutcome.NOT_MET;
        }
        if (longObservation.available() && shortObservation.available()) {
            return BurnRateBandOutcome.MET;
        }
        return BurnRateBandOutcome.UNAVAILABLE;
    }

    private static boolean belowThreshold(WindowBurnRateObservation observation, BurnRateBand band) {
        return observation.available() && observation.observedBurnRate().compareTo(band.threshold()) < 0;
    }
}
