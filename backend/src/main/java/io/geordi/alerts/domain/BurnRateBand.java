package io.geordi.alerts.domain;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;

public record BurnRateBand(
        AlertObservationWindow longWindow,
        AlertObservationWindow shortWindow,
        BigDecimal threshold) implements Comparable<BurnRateBand> {

    public BurnRateBand {
        Objects.requireNonNull(longWindow, "burn-rate band long window must not be null");
        Objects.requireNonNull(shortWindow, "burn-rate band short window must not be null");
        if (!supportedPair(longWindow, shortWindow)) {
            throw new IllegalArgumentException("unsupported burn-rate band window pair");
        }
        threshold = BurnRateThreshold.normalize(threshold, "burn-rate band threshold");
    }

    public int canonicalRank() {
        return longWindow == AlertObservationWindow.PT1H ? 0 : 1;
    }

    public List<AlertObservationWindow> observationWindows() {
        return List.of(shortWindow, longWindow);
    }

    @Override
    public int compareTo(BurnRateBand other) {
        Objects.requireNonNull(other, "burn-rate band must not be null");
        return Integer.compare(canonicalRank(), other.canonicalRank());
    }

    private static boolean supportedPair(
            AlertObservationWindow longWindow, AlertObservationWindow shortWindow) {
        return longWindow == AlertObservationWindow.PT1H && shortWindow == AlertObservationWindow.PT5M
                || longWindow == AlertObservationWindow.PT6H && shortWindow == AlertObservationWindow.PT30M;
    }
}
