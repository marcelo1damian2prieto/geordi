package io.geordi.slos.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.BurnRateStatus;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import io.geordi.slos.domain.SloStatus;
import io.geordi.slos.domain.UnavailableReason;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import org.junit.jupiter.api.Test;

class SloEvaluationServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-20T18:00:00Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("checkout", "commerce", "production");

    @Test
    void evaluatesAvailabilityAndErrorRateWithInclusiveTargetEquality() {
        assertEvaluation(SliType.AVAILABILITY, "0.999", 1000d, 1d, SloStatus.MET, "0.999");
        assertEvaluation(SliType.AVAILABILITY, "0.999", 1000d, 2d, SloStatus.BREACHED, "0.998");
        assertEvaluation(SliType.ERROR_RATE, "0.001", 1000d, 1d, SloStatus.MET, "0.001");
        assertEvaluation(SliType.ERROR_RATE, "0.001", 1000d, 2d, SloStatus.BREACHED, "0.002");
    }

    @Test
    void derivesSliAwareBurnRatesFromTheSameAtomicMeasurement() {
        assertBurn(SliType.AVAILABILITY, "0.999", 1000d, 0d, "0", BurnRateStatus.AVAILABLE);
        assertBurn(SliType.AVAILABILITY, "0.999", 1000d, 0.5d, "0.5", BurnRateStatus.AVAILABLE);
        assertBurn(SliType.AVAILABILITY, "0.999", 1000d, 1d, "1", BurnRateStatus.AVAILABLE);
        assertBurn(SliType.AVAILABILITY, "0.999", 1000d, 4d, "4", BurnRateStatus.AVAILABLE);
        assertBurn(SliType.ERROR_RATE, "0.001", 1000d, 4d, "4", BurnRateStatus.AVAILABLE);
    }

    @Test
    void roundsNonTerminatingRatiosToTwelveSignificantDigitsAndCalculatesBurnDirectlyFromCounts() {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE,
                SliType.ERROR_RATE, new BigDecimal("0.2"), EvaluationWindow.PT5M, true);

        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(3d, 1d))
                .evaluate(definition.id());

        assertThat(result.observedValue()).isEqualByComparingTo("0.333333333333");
        assertThat(result.burnRateEvaluation().observedBadRatio())
                .isEqualByComparingTo("0.333333333333");
        assertThat(result.burnRateEvaluation().burnRate()).isEqualByComparingTo("1.66666666667");
        assertThat(result.status()).isEqualTo(SloStatus.BREACHED);
    }

    @Test
    void preservesNonzeroBadRatioBelowFixedScaleTwelve() {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE,
                SliType.ERROR_RATE, new BigDecimal("0.001"), EvaluationWindow.PT5M, true);

        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(3_000_000_000_000d, 1d))
                .evaluate(definition.id());

        assertThat(result.observedValue()).isEqualByComparingTo("3.33333333333E-13");
        assertThat(result.burnRateEvaluation().observedBadRatio())
                .isEqualByComparingTo("3.33333333333E-13");
        assertThat(result.burnRateEvaluation().burnRate()).isEqualByComparingTo("3.33333333333E-10");
        assertThat(result.burnRateEvaluation().observedBadRatio()).isNotZero();
        assertThat(result.status()).isEqualTo(SloStatus.MET);
    }

    @Test
    void doesNotExposeAValidRatioThatJavaScriptWouldUnderflowToZero() {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE,
                SliType.ERROR_RATE, new BigDecimal("0.001"), EvaluationWindow.PT5M, true);

        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(
                Double.MAX_VALUE, Double.MIN_VALUE)).evaluate(definition.id());

        assertThat(result.status()).isEqualTo(SloStatus.UNAVAILABLE);
        assertThat(result.reason()).isEqualTo(UnavailableReason.INVALID_TELEMETRY);
        assertThat(result.burnRateEvaluation().observedBadRatio()).isNull();
        assertThat(result.burnRateEvaluation().burnRate()).isNull();
    }

    @Test
    void representsZeroAllowedBadRatioWithoutNonFiniteValuesAndPreservesSloStatus() {
        assertZeroBudget(SliType.AVAILABILITY, "1", 1000d, 0d, SloStatus.MET, "0");
        assertZeroBudget(SliType.AVAILABILITY, "1", 1000d, 1d, SloStatus.BREACHED, "0.001");
        assertZeroBudget(SliType.ERROR_RATE, "0", 1000d, 0d, SloStatus.MET, "0");
        assertZeroBudget(SliType.ERROR_RATE, "0", 1000d, 1d, SloStatus.BREACHED, "0.001");
    }

    @Test
    void protectsTheExactNinetyNinePointNinePercentBoundaryInBothDirections() {
        assertEvaluation(SliType.AVAILABILITY, "0.999", 10_000d, 9d, SloStatus.MET, "0.9991");
        assertEvaluation(SliType.AVAILABILITY, "0.999", 10_000d, 10d, SloStatus.MET, "0.999");
        assertEvaluation(SliType.AVAILABILITY, "0.999", 10_000d, 11d, SloStatus.BREACHED, "0.9989");
        assertEvaluation(SliType.ERROR_RATE, "0.001", 10_000d, 9d, SloStatus.MET, "0.0009");
        assertEvaluation(SliType.ERROR_RATE, "0.001", 10_000d, 10d, SloStatus.MET, "0.001");
        assertEvaluation(SliType.ERROR_RATE, "0.001", 10_000d, 11d, SloStatus.BREACHED, "0.0011");
    }

    @Test
    void distinguishesDisabledNoTrafficMissingAndInvalidTelemetry() {
        assertUnavailable(definition(false), new RequestOutcomeMeasurement(10d, 0d), UnavailableReason.DISABLED);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(0d, 0d), UnavailableReason.NO_TRAFFIC);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(null, 0d),
                UnavailableReason.MISSING_REQUEST_COUNT);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(10d, null),
                UnavailableReason.MISSING_ERROR_COUNT);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(10d, 11d),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(-1d, 0d),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(10d, -1d),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(Double.NaN, 0d),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(Double.POSITIVE_INFINITY, 0d),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(10d, Double.POSITIVE_INFINITY),
                UnavailableReason.INVALID_TELEMETRY);
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(Double.NEGATIVE_INFINITY, 0d),
                UnavailableReason.INVALID_TELEMETRY);
    }

    @Test
    void mapsMetricsFailureToUnavailableAndUsesOneFixedHalfOpenRange() {
        SloDefinition definition = definition(true);
        SloDefinitionCatalog catalog = catalog(definition);
        RequestOutcomeMeasurementPort port = request -> {
            assertThat(request.range().from()).isEqualTo(NOW.minusSeconds(300));
            assertThat(request.range().to()).isEqualTo(NOW);
            throw new MetricsMeasurementUnavailableException("metrics unavailable");
        };

        var result = service(catalog, port).evaluate(definition.id());

        assertThat(result.status()).isEqualTo(SloStatus.UNAVAILABLE);
        assertThat(result.reason()).isEqualTo(UnavailableReason.METRICS_UNAVAILABLE);
        assertThat(result.observedValue()).isNull();
        assertThat(result.burnRateEvaluation().status()).isEqualTo(BurnRateStatus.UNAVAILABLE);
        assertThat(result.burnRateEvaluation().reason())
                .isEqualTo(BurnRateUnavailableReason.METRICS_UNAVAILABLE);
    }

    @Test
    void usesTheDefinitionIdentityAndRangeForExactlyOneMeasurement() {
        SloDefinition definition = definition(true);
        int[] calls = {0};
        RequestOutcomeMeasurementPort port = request -> {
            calls[0]++;
            assertThat(request.service()).isEqualTo(SERVICE);
            assertThat(request.range()).isEqualTo(new io.geordi.slos.domain.TimeRange(
                    NOW.minusSeconds(300), NOW));
            return new RequestOutcomeMeasurement(1000d, 1d);
        };

        service(catalog(definition), port).evaluate(definition.id());

        assertThat(calls[0]).isOne();
    }

    @Test
    void disabledDefinitionDoesNotMeasureBurnEvidence() {
        SloDefinition definition = definition(false);
        int[] calls = {0};

        var result = service(catalog(definition), request -> {
            calls[0]++;
            return new RequestOutcomeMeasurement(1000d, 0d);
        }).evaluate(definition.id());

        assertThat(calls[0]).isZero();
        assertThat(result.status()).isEqualTo(SloStatus.UNAVAILABLE);
        assertThat(result.burnRateEvaluation().reason()).isEqualTo(BurnRateUnavailableReason.DISABLED);
    }

    private static void assertEvaluation(
            SliType type, String target, double requests, double errors, SloStatus status, String observed) {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE, type,
                new BigDecimal(target), EvaluationWindow.PT5M, true);
        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(requests, errors))
                .evaluate(definition.id());
        assertThat(result.status()).isEqualTo(status);
        assertThat(result.observedValue()).isEqualByComparingTo(observed);
        assertThat(result.requestCount()).isEqualByComparingTo(BigDecimal.valueOf(requests));
        assertThat(result.reason()).isNull();
    }

    @Test
    void preservesFractionalProviderCounterIncreasesWithoutRounding() {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE,
                SliType.ERROR_RATE, new BigDecimal("0.1"), EvaluationWindow.PT5M, true);

        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(10.5d, 1.05d))
                .evaluate(definition.id());

        assertThat(result.status()).isEqualTo(SloStatus.MET);
        assertThat(result.observedValue()).isEqualByComparingTo("0.1");
        assertThat(result.requestCount()).isEqualByComparingTo("10.5");
    }

    private static void assertUnavailable(
            SloDefinition definition, RequestOutcomeMeasurement measurement, UnavailableReason reason) {
        var result = service(catalog(definition), ignored -> measurement).evaluate(definition.id());
        assertThat(result.status()).isEqualTo(SloStatus.UNAVAILABLE);
        assertThat(result.reason()).isEqualTo(reason);
        assertThat(result.observedValue()).isNull();
        assertThat(result.burnRateEvaluation().status()).isEqualTo(BurnRateStatus.UNAVAILABLE);
        assertThat(result.burnRateEvaluation().reason().name()).isEqualTo(reason.name());
        assertThat(result.burnRateEvaluation().observedBadRatio()).isNull();
        assertThat(result.burnRateEvaluation().burnRate()).isNull();
    }

    private static void assertBurn(
            SliType type, String target, double requests, double errors, String burnRate, BurnRateStatus status) {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE, type,
                new BigDecimal(target), EvaluationWindow.PT5M, true);
        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(requests, errors))
                .evaluate(definition.id());

        assertThat(result.burnRateEvaluation().allowedBadRatio()).isEqualByComparingTo("0.001");
        assertThat(result.burnRateEvaluation().observedBadRatio())
                .isEqualByComparingTo(BigDecimal.valueOf(errors).divide(BigDecimal.valueOf(requests)));
        assertThat(result.burnRateEvaluation().burnRate()).isEqualByComparingTo(burnRate);
        assertThat(result.burnRateEvaluation().status()).isEqualTo(status);
        assertThat(result.burnRateEvaluation().reason()).isNull();
    }

    private static void assertZeroBudget(
            SliType type, String target, double requests, double errors, SloStatus sloStatus, String observedBadRatio) {
        SloDefinition definition = new SloDefinition("objective", "Objective", null, SERVICE, type,
                new BigDecimal(target), EvaluationWindow.PT5M, true);
        var result = service(catalog(definition), ignored -> new RequestOutcomeMeasurement(requests, errors))
                .evaluate(definition.id());

        assertThat(result.status()).isEqualTo(sloStatus);
        assertThat(result.burnRateEvaluation().allowedBadRatio()).isZero();
        assertThat(result.burnRateEvaluation().observedBadRatio()).isEqualByComparingTo(observedBadRatio);
        assertThat(result.burnRateEvaluation().burnRate()).isNull();
        assertThat(result.burnRateEvaluation().status()).isEqualTo(BurnRateStatus.UNAVAILABLE);
        assertThat(result.burnRateEvaluation().reason())
                .isEqualTo(BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO);
    }

    private static SloDefinition definition(boolean enabled) {
        return new SloDefinition("objective", "Objective", null, SERVICE, SliType.AVAILABILITY,
                new BigDecimal("0.999"), EvaluationWindow.PT5M, enabled);
    }

    private static SloDefinitionCatalog catalog(SloDefinition definition) {
        return new SloDefinitionCatalog() {
            @Override
            public List<SloDefinition> findAll() {
                return List.of(definition);
            }

            @Override
            public java.util.Optional<SloDefinition> findById(String id) {
                return definition.id().equals(id) ? java.util.Optional.of(definition) : java.util.Optional.empty();
            }
        };
    }

    private static SloEvaluationService service(
            SloDefinitionCatalog catalog, RequestOutcomeMeasurementPort measurementPort) {
        return new SloEvaluationService(catalog, measurementPort, Clock.fixed(NOW, ZoneOffset.UTC));
    }
}
