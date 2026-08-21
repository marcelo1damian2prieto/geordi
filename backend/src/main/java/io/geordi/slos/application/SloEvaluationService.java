package io.geordi.slos.application;

import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.BurnRateEvaluation;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.SliSemantics;
import io.geordi.slos.domain.SloDefinition;
import io.geordi.slos.domain.SloEvaluation;
import io.geordi.slos.domain.SloStatus;
import io.geordi.slos.domain.TimeRange;
import io.geordi.slos.domain.UnavailableReason;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.util.Objects;

public final class SloEvaluationService implements SloEvaluationUseCase {

    private final SloDefinitionCatalog catalog;
    private final RequestOutcomeMeasurementPort measurementPort;
    private final Clock clock;

    public SloEvaluationService(
            SloDefinitionCatalog catalog,
            RequestOutcomeMeasurementPort measurementPort,
            Clock clock) {
        this.catalog = Objects.requireNonNull(catalog, "SLO catalog must not be null");
        this.measurementPort = Objects.requireNonNull(measurementPort, "measurement port must not be null");
        this.clock = Objects.requireNonNull(clock, "clock must not be null");
    }

    @Override
    public SloEvaluation evaluate(String id) {
        SloDefinition definition = catalog.findById(id).orElseThrow(SloNotFoundException::new);
        Instant evaluatedAt = clock.instant();
        TimeRange range = new TimeRange(evaluatedAt.minus(definition.window().duration()), evaluatedAt);
        if (!definition.enabled()) {
            return unavailable(definition, range, evaluatedAt, null, UnavailableReason.DISABLED);
        }

        RequestOutcomeMeasurement measurement;
        try {
            measurement = measurementPort.measure(new RequestOutcomeMeasurementRequest(definition.service(), range));
        } catch (MetricsMeasurementUnavailableException exception) {
            return unavailable(definition, range, evaluatedAt, null, UnavailableReason.METRICS_UNAVAILABLE);
        }
        if (measurement == null || measurement.requestCount() == null) {
            return unavailable(definition, range, evaluatedAt, null, UnavailableReason.MISSING_REQUEST_COUNT);
        }
        if (measurement.errorCount() == null) {
            return unavailable(definition, range, evaluatedAt, null, UnavailableReason.MISSING_ERROR_COUNT);
        }
        Double requests = measurement.requestCount();
        Double errors = measurement.errorCount();
        if (!finiteNonNegative(requests) || !finiteNonNegative(errors) || errors > requests) {
            return unavailable(definition, range, evaluatedAt, null, UnavailableReason.INVALID_TELEMETRY);
        }
        BigDecimal requestCount = BigDecimal.valueOf(requests);
        BigDecimal errorCount = BigDecimal.valueOf(errors);
        if (requestCount.signum() == 0) {
            return unavailable(definition, range, evaluatedAt, BigDecimal.ZERO, UnavailableReason.NO_TRAFFIC);
        }

        BigDecimal observed = SliSemantics.observedValue(definition.sliType(), requestCount, errorCount);
        BigDecimal observedBadRatio = SliSemantics.observedBadRatio(requestCount, errorCount);
        if (!SliSemantics.isJsonSafeNumber(observed) || !SliSemantics.isJsonSafeNumber(observedBadRatio)) {
            return unavailable(definition, range, evaluatedAt, requestCount, UnavailableReason.INVALID_TELEMETRY);
        }
        boolean met = SliSemantics.meetsTarget(
                definition.sliType(), definition.target(), requestCount, errorCount);
        BurnRateEvaluation burnRateEvaluation = burnRate(
                definition, requestCount, errorCount, observedBadRatio);
        return new SloEvaluation(
                definition.id(), definition.service(), definition.sliType(), definition.target(), definition.window(),
                range, evaluatedAt, observed, requestCount, met ? SloStatus.MET : SloStatus.BREACHED, null,
                burnRateEvaluation);
    }

    private static boolean finiteNonNegative(Double value) {
        return Double.isFinite(value) && value >= 0;
    }

    private static SloEvaluation unavailable(
            SloDefinition definition,
            TimeRange range,
            Instant evaluatedAt,
            BigDecimal requestCount,
            UnavailableReason reason) {
        BigDecimal allowedBadRatio = SliSemantics.allowedBadRatio(definition.sliType(), definition.target());
        BurnRateEvaluation burnRateEvaluation = BurnRateEvaluation.unavailable(
                allowedBadRatio, BurnRateUnavailableReason.valueOf(reason.name()));
        return new SloEvaluation(
                definition.id(), definition.service(), definition.sliType(), definition.target(), definition.window(),
                range, evaluatedAt, null, requestCount, SloStatus.UNAVAILABLE, reason, burnRateEvaluation);
    }

    private static BurnRateEvaluation burnRate(
            SloDefinition definition,
            BigDecimal requestCount,
            BigDecimal errorCount,
            BigDecimal observedBadRatio) {
        BigDecimal allowedBadRatio = SliSemantics.allowedBadRatio(definition.sliType(), definition.target());
        if (allowedBadRatio.signum() == 0) {
            return BurnRateEvaluation.unavailableWithObservedBadRatio(
                    allowedBadRatio, observedBadRatio, BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO);
        }
        return BurnRateEvaluation.available(
                allowedBadRatio, observedBadRatio,
                SliSemantics.burnRate(requestCount, errorCount, allowedBadRatio));
    }
}
