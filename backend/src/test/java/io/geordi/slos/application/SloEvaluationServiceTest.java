package io.geordi.slos.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
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
        assertUnavailable(definition(true), new RequestOutcomeMeasurement(Double.NaN, 0d),
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
