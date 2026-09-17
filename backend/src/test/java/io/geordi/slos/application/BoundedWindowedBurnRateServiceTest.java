package io.geordi.slos.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class BoundedWindowedBurnRateServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-20T18:00:00Z");
    private static final Duration FIVE_MINUTES = Duration.ofMinutes(5);
    private static final Duration THIRTY_MINUTES = Duration.ofMinutes(30);
    private static final Duration ONE_HOUR = Duration.ofHours(1);
    private static final Duration SIX_HOURS = Duration.ofHours(6);
    private static final ServiceIdentity SERVICE = new ServiceIdentity("checkout", "commerce", "production");

    @Test
    void resolvesOnceCapturesOneInstantAndMeasuresTheFullCanonicalUnionOnce() {
        AtomicInteger resolutions = new AtomicInteger();
        AtomicInteger measurements = new AtomicInteger();
        SloDefinition definition = definition(true);
        SloDefinitionCatalog catalog = catalog(definition, resolutions);
        RequestOutcomeMeasurementPort port = boundedPort(request -> {
            measurements.incrementAndGet();
            assertThat(request.service()).isEqualTo(SERVICE);
            assertThat(request.ranges()).containsOnlyKeys(FIVE_MINUTES, THIRTY_MINUTES, ONE_HOUR, SIX_HOURS);
            request.ranges().forEach((window, range) -> {
                assertThat(range.from()).isEqualTo(NOW.minus(window));
                assertThat(range.to()).isEqualTo(NOW);
            });
            Map<Duration, RequestOutcomeMeasurement> result = new LinkedHashMap<>();
            request.ranges().keySet().forEach(window -> result.put(window, new RequestOutcomeMeasurement(1000d, 1d)));
            return new BoundedRequestOutcomeMeasurement(result);
        });

        var result = service(catalog, port).evaluate(
                definition.id(), new BoundedObservationWindowRequest(
                        Set.of(SIX_HOURS, FIVE_MINUTES, ONE_HOUR, THIRTY_MINUTES)));

        assertThat(resolutions).hasValue(1);
        assertThat(measurements).hasValue(1);
        assertThat(result.sloId()).isEqualTo(definition.id());
        assertThat(result.service()).isEqualTo(SERVICE);
        assertThat(result.configuredSloWindow()).isEqualTo(EvaluationWindow.PT15M);
        assertThat(result.evaluatedAt()).isEqualTo(NOW);
        assertThat(result.observations())
                .extracting(WindowedBurnRateObservation::observationWindow)
                .containsExactly(FIVE_MINUTES, THIRTY_MINUTES, ONE_HOUR, SIX_HOURS);
        assertThat(result.observations())
                .extracting(WindowedBurnRateObservation::observedBurnRate)
                .allSatisfy(burnRate -> assertThat(burnRate).isEqualByComparingTo("1"));
    }

    @Test
    void disabledSloReturnsTimedEvidenceForEveryWindowWithoutProviderWork() {
        AtomicInteger measurements = new AtomicInteger();
        SloDefinition definition = definition(false);

        var result = service(catalog(definition, new AtomicInteger()), boundedPort(request -> {
            measurements.incrementAndGet();
            return new BoundedRequestOutcomeMeasurement(Map.of());
        })).evaluate(definition.id(), request(FIVE_MINUTES, ONE_HOUR));

        assertThat(measurements).hasValue(0);
        assertThat(result.evaluatedAt()).isEqualTo(NOW);
        assertThat(result.observations()).allSatisfy(observation -> {
            assertThat(observation.observedBurnRate()).isNull();
            assertThat(observation.reason()).isEqualTo(BurnRateUnavailableReason.DISABLED);
            assertThat(observation.range().to()).isEqualTo(NOW);
            assertThat(observation.range().from()).isEqualTo(NOW.minus(observation.observationWindow()));
        });
    }

    @Test
    void preservesEveryBoundedUnavailableReasonAndNeverTurnsMissingWindowsIntoZero() {
        SloDefinition definition = definition(true);
        Map<Duration, RequestOutcomeMeasurement> measurements = Map.of(
                FIVE_MINUTES, new RequestOutcomeMeasurement(0d, 0d),
                THIRTY_MINUTES, new RequestOutcomeMeasurement(10d, null),
                ONE_HOUR, new RequestOutcomeMeasurement(10d, 11d));
        var result = service(catalog(definition, new AtomicInteger()),
                boundedPort(ignored -> new BoundedRequestOutcomeMeasurement(measurements)))
                .evaluate(definition.id(), request(FIVE_MINUTES, THIRTY_MINUTES, ONE_HOUR, SIX_HOURS));

        assertThat(result.observations()).extracting(WindowedBurnRateObservation::reason)
                .containsExactly(
                        BurnRateUnavailableReason.NO_TRAFFIC,
                        BurnRateUnavailableReason.MISSING_ERROR_COUNT,
                        BurnRateUnavailableReason.INVALID_TELEMETRY,
                        BurnRateUnavailableReason.MISSING_REQUEST_COUNT);
        assertThat(result.observations()).extracting(WindowedBurnRateObservation::observedBurnRate)
                .containsOnlyNulls();
    }

    @Test
    void mapsOneProviderWideFailureOrCorruptExtraResultToAllMetricsUnavailable() {
        SloDefinition definition = definition(true);
        RequestOutcomeMeasurementPort failure = boundedPort(ignored -> {
            throw new MetricsMeasurementUnavailableException("deadline");
        });
        var failed = service(catalog(definition, new AtomicInteger()), failure)
                .evaluate(definition.id(), request(FIVE_MINUTES, ONE_HOUR));
        var corrupt = service(catalog(definition, new AtomicInteger()), boundedPort(ignored ->
                new BoundedRequestOutcomeMeasurement(Map.of(
                        FIVE_MINUTES, new RequestOutcomeMeasurement(10d, 0d),
                        Duration.ofMinutes(15), new RequestOutcomeMeasurement(10d, 0d)))))
                .evaluate(definition.id(), request(FIVE_MINUTES, ONE_HOUR));

        assertThat(failed.observations()).extracting(WindowedBurnRateObservation::reason)
                .containsOnly(BurnRateUnavailableReason.METRICS_UNAVAILABLE);
        assertThat(corrupt.observations()).extracting(WindowedBurnRateObservation::reason)
                .containsOnly(BurnRateUnavailableReason.METRICS_UNAVAILABLE);
    }

    @Test
    void preservesZeroBudgetAndPositiveZeroErrorBurnSemantics() {
        SloDefinition zeroBudget = new SloDefinition(
                "perfect", "Perfect", null, SERVICE, SliType.AVAILABILITY,
                BigDecimal.ONE, EvaluationWindow.PT5M, true);
        var unavailable = service(catalog(zeroBudget, new AtomicInteger()), boundedPort(ignored ->
                new BoundedRequestOutcomeMeasurement(Map.of(
                        FIVE_MINUTES, new RequestOutcomeMeasurement(10d, 0d),
                        ONE_HOUR, new RequestOutcomeMeasurement(10d, 0d)))))
                .evaluate(zeroBudget.id(), request(FIVE_MINUTES, ONE_HOUR));

        SloDefinition regular = definition(true);
        var available = service(catalog(regular, new AtomicInteger()), boundedPort(ignored ->
                new BoundedRequestOutcomeMeasurement(Map.of(
                        FIVE_MINUTES, new RequestOutcomeMeasurement(10d, 0d),
                        ONE_HOUR, new RequestOutcomeMeasurement(10d, 0d)))))
                .evaluate(regular.id(), request(FIVE_MINUTES, ONE_HOUR));

        assertThat(unavailable.observations()).extracting(WindowedBurnRateObservation::reason)
                .containsOnly(BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO);
        assertThat(available.observations()).extracting(WindowedBurnRateObservation::observedBurnRate)
                .allSatisfy(value -> assertThat(value).isZero());
    }

    @Test
    void classifiesNonFiniteRequestEvidenceAsInvalidTelemetry() {
        SloDefinition definition = definition(true);
        var result = service(catalog(definition, new AtomicInteger()), boundedPort(ignored ->
                new BoundedRequestOutcomeMeasurement(Map.of(
                        FIVE_MINUTES, new RequestOutcomeMeasurement(Double.NaN, 0d),
                        ONE_HOUR, new RequestOutcomeMeasurement(10d, 0d)))))
                .evaluate(definition.id(), request(FIVE_MINUTES, ONE_HOUR));

        assertThat(result.observations().getFirst().reason()).isEqualTo(BurnRateUnavailableReason.INVALID_TELEMETRY);
        assertThat(result.observations().get(1).observedBurnRate()).isZero();
    }

    @Test
    void rejectsUnboundedDuplicateAndUnsupportedRequestsBeforeResolutionOrProviderWork() {
        assertThatThrownBy(() -> new BoundedObservationWindowRequest(List.of(FIVE_MINUTES)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new BoundedObservationWindowRequest(
                List.of(FIVE_MINUTES, THIRTY_MINUTES, ONE_HOUR, SIX_HOURS, Duration.ofHours(12))))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new BoundedObservationWindowRequest(List.of(FIVE_MINUTES, FIVE_MINUTES)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new BoundedObservationWindowRequest(
                Set.of(FIVE_MINUTES, Duration.ofMinutes(15))))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static BoundedObservationWindowRequest request(Duration... windows) {
        return new BoundedObservationWindowRequest(Set.of(windows));
    }

    private static RequestOutcomeMeasurementPort boundedPort(BoundedMeasurement operation) {
        return new RequestOutcomeMeasurementPort() {
            @Override
            public RequestOutcomeMeasurement measure(RequestOutcomeMeasurementRequest request) {
                throw new AssertionError("scalar measurement must not be used");
            }

            @Override
            public BoundedRequestOutcomeMeasurement measureBounded(
                    BoundedRequestOutcomeMeasurementRequest request) {
                return operation.measure(request);
            }
        };
    }

    private static SloDefinition definition(boolean enabled) {
        return new SloDefinition(
                "checkout-availability", "Checkout availability", null, SERVICE, SliType.AVAILABILITY,
                new BigDecimal("0.999"), EvaluationWindow.PT15M, enabled);
    }

    private static SloDefinitionCatalog catalog(SloDefinition definition, AtomicInteger resolutions) {
        return new SloDefinitionCatalog() {
            @Override
            public List<SloDefinition> findAll() {
                return List.of(definition);
            }

            @Override
            public Optional<SloDefinition> findById(String id) {
                resolutions.incrementAndGet();
                return definition.id().equals(id) ? Optional.of(definition) : Optional.empty();
            }
        };
    }

    private static BoundedWindowedBurnRateService service(
            SloDefinitionCatalog catalog, RequestOutcomeMeasurementPort port) {
        return new BoundedWindowedBurnRateService(catalog, port, Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @FunctionalInterface
    private interface BoundedMeasurement {
        BoundedRequestOutcomeMeasurement measure(BoundedRequestOutcomeMeasurementRequest request);
    }
}
