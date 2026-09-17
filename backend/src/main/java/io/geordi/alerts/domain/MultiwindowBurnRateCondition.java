package io.geordi.alerts.domain;

import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

public record MultiwindowBurnRateCondition(List<BurnRateBand> bands) implements AlertCondition {

    private static final int MAXIMUM_BANDS = 2;

    public MultiwindowBurnRateCondition {
        Objects.requireNonNull(bands, "multiwindow burn-rate bands must not be null");
        if (bands.isEmpty() || bands.size() > MAXIMUM_BANDS || bands.stream().anyMatch(Objects::isNull)) {
            throw new IllegalArgumentException("multiwindow burn-rate condition requires one or two bands");
        }
        if (bands.stream().map(BurnRateBand::canonicalRank).distinct().count() != bands.size()) {
            throw new IllegalArgumentException("multiwindow burn-rate condition contains a duplicate band");
        }
        bands = bands.stream().sorted(Comparator.naturalOrder()).toList();
    }

    @Override
    public AlertConditionType type() {
        return AlertConditionType.MULTIWINDOW_BURN_RATE;
    }

    public Set<AlertObservationWindow> observationWindows() {
        LinkedHashSet<AlertObservationWindow> windows = new LinkedHashSet<>();
        bands.stream()
                .flatMap(band -> band.observationWindows().stream())
                .sorted(Comparator.comparingInt(AlertObservationWindow::canonicalRank))
                .forEach(windows::add);
        return Collections.unmodifiableSet(windows);
    }

    public List<BurnRateBandResult> evaluate(MultiwindowBurnRateEvidence evidence) {
        Objects.requireNonNull(evidence, "multiwindow burn-rate evidence must not be null");
        if (!observationWindows().equals(evidence.observationWindows())) {
            throw new IllegalArgumentException("multiwindow evidence does not match condition windows");
        }
        return bands.stream().map(band -> BurnRateBandResult.evaluate(band, evidence)).toList();
    }

    public AlertEvaluationStatus evaluateStatus(MultiwindowBurnRateEvidence evidence) {
        List<BurnRateBandResult> results = evaluate(evidence);
        if (results.stream().anyMatch(result -> result.outcome() == BurnRateBandOutcome.MET)) {
            return AlertEvaluationStatus.CONDITION_MET;
        }
        if (results.stream().allMatch(result -> result.outcome() == BurnRateBandOutcome.NOT_MET)) {
            return AlertEvaluationStatus.CONDITION_NOT_MET;
        }
        return AlertEvaluationStatus.UNAVAILABLE;
    }
}
