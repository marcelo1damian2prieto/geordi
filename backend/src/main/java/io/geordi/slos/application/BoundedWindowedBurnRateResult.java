package io.geordi.slos.application;

import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import java.time.Duration;
import java.time.Instant;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;

public record BoundedWindowedBurnRateResult(
        String sloId,
        ServiceIdentity service,
        EvaluationWindow configuredSloWindow,
        Instant evaluatedAt,
        List<WindowedBurnRateObservation> observations) {

    public BoundedWindowedBurnRateResult {
        Objects.requireNonNull(sloId, "SLO id must not be null");
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(configuredSloWindow, "configured SLO window must not be null");
        Objects.requireNonNull(evaluatedAt, "evaluated at must not be null");
        observations = List.copyOf(Objects.requireNonNull(observations, "observations must not be null"));
        List<Duration> windows = observations.stream()
                .map(WindowedBurnRateObservation::observationWindow)
                .toList();
        new BoundedObservationWindowRequest(windows);
        if (new HashSet<>(windows).size() != observations.size()) {
            throw new IllegalArgumentException("observations must not contain duplicate windows");
        }
        for (WindowedBurnRateObservation observation : observations) {
            if (!observation.range().to().equals(evaluatedAt)
                    || !observation.range().from().equals(evaluatedAt.minus(observation.observationWindow()))) {
                throw new IllegalArgumentException("observation range must match its window and evaluated at");
            }
        }
    }
}
