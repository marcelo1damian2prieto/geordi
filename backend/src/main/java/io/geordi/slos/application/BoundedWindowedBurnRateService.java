package io.geordi.slos.application;

import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.SliSemantics;
import io.geordi.slos.domain.SloDefinition;
import io.geordi.slos.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public final class BoundedWindowedBurnRateService implements BoundedWindowedBurnRateUseCase {

    private final SloDefinitionCatalog catalog;
    private final RequestOutcomeMeasurementPort measurementPort;
    private final Clock clock;

    public BoundedWindowedBurnRateService(
            SloDefinitionCatalog catalog, RequestOutcomeMeasurementPort measurementPort, Clock clock) {
        this.catalog = Objects.requireNonNull(catalog, "SLO catalog must not be null");
        this.measurementPort = Objects.requireNonNull(measurementPort, "measurement port must not be null");
        this.clock = Objects.requireNonNull(clock, "clock must not be null");
    }

    @Override
    public BoundedWindowedBurnRateResult evaluate(String sloId, BoundedObservationWindowRequest request) {
        Objects.requireNonNull(request, "bounded observation request must not be null");
        SloDefinition definition = catalog.findById(sloId).orElseThrow(SloNotFoundException::new);
        Instant evaluatedAt = clock.instant();
        Map<Duration, TimeRange> ranges = ranges(request, evaluatedAt);
        if (!definition.enabled()) {
            return result(definition, evaluatedAt, unavailable(ranges, BurnRateUnavailableReason.DISABLED));
        }

        BoundedRequestOutcomeMeasurement batch;
        try {
            batch = measurementPort.measureBounded(
                    new BoundedRequestOutcomeMeasurementRequest(definition.service(), ranges));
        } catch (MetricsMeasurementUnavailableException exception) {
            return result(definition, evaluatedAt,
                    unavailable(ranges, BurnRateUnavailableReason.METRICS_UNAVAILABLE));
        }
        if (batch == null || hasUnknownWindow(batch, ranges)) {
            return result(definition, evaluatedAt,
                    unavailable(ranges, BurnRateUnavailableReason.METRICS_UNAVAILABLE));
        }

        List<WindowedBurnRateObservation> observations = new ArrayList<>();
        for (Duration window : request.observationWindows()) {
            RequestOutcomeMeasurement measurement = batch.measurements().get(window);
            observations.add(observation(definition, window, ranges.get(window), measurement));
        }
        return result(definition, evaluatedAt, observations);
    }

    private static Map<Duration, TimeRange> ranges(BoundedObservationWindowRequest request, Instant evaluatedAt) {
        Map<Duration, TimeRange> ranges = new LinkedHashMap<>();
        for (Duration window : request.observationWindows()) {
            ranges.put(window, new TimeRange(evaluatedAt.minus(window), evaluatedAt));
        }
        return ranges;
    }

    private static boolean hasUnknownWindow(
            BoundedRequestOutcomeMeasurement batch, Map<Duration, TimeRange> requestedRanges) {
        return !requestedRanges.keySet().containsAll(batch.measurements().keySet());
    }

    private static List<WindowedBurnRateObservation> unavailable(
            Map<Duration, TimeRange> ranges, BurnRateUnavailableReason reason) {
        return ranges.entrySet().stream()
                .map(entry -> WindowedBurnRateObservation.unavailable(entry.getKey(), entry.getValue(), reason))
                .toList();
    }

    private static WindowedBurnRateObservation observation(
            SloDefinition definition,
            Duration window,
            TimeRange range,
            RequestOutcomeMeasurement measurement) {
        if (measurement == null || measurement.requestCount() == null) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.MISSING_REQUEST_COUNT);
        }
        if (measurement.errorCount() == null) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.MISSING_ERROR_COUNT);
        }
        double requests = measurement.requestCount();
        double errors = measurement.errorCount();
        if (!finiteNonNegative(requests) || !finiteNonNegative(errors) || errors > requests) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.INVALID_TELEMETRY);
        }
        BigDecimal requestCount = BigDecimal.valueOf(requests);
        BigDecimal errorCount = BigDecimal.valueOf(errors);
        if (requestCount.signum() == 0) {
            return WindowedBurnRateObservation.unavailable(window, range, BurnRateUnavailableReason.NO_TRAFFIC);
        }
        BigDecimal observedBadRatio = SliSemantics.observedBadRatio(requestCount, errorCount);
        if (!SliSemantics.isJsonSafeNumber(observedBadRatio)) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.INVALID_TELEMETRY);
        }
        BigDecimal allowedBadRatio = SliSemantics.allowedBadRatio(definition.sliType(), definition.target());
        if (allowedBadRatio.signum() == 0) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO);
        }
        BigDecimal burnRate = SliSemantics.burnRate(requestCount, errorCount, allowedBadRatio);
        if (!SliSemantics.isJsonSafeNumber(burnRate)) {
            return WindowedBurnRateObservation.unavailable(
                    window, range, BurnRateUnavailableReason.INVALID_TELEMETRY);
        }
        return WindowedBurnRateObservation.available(window, range, burnRate);
    }

    private static boolean finiteNonNegative(double value) {
        return Double.isFinite(value) && value >= 0;
    }

    private static BoundedWindowedBurnRateResult result(
            SloDefinition definition, Instant evaluatedAt, List<WindowedBurnRateObservation> observations) {
        return new BoundedWindowedBurnRateResult(
                definition.id(), definition.service(), definition.window(), evaluatedAt, observations);
    }
}
