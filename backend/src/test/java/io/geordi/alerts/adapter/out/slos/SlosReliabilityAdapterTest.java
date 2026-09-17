package io.geordi.alerts.adapter.out.slos;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.slos.application.BoundedObservationWindowRequest;
import io.geordi.slos.application.BoundedWindowedBurnRateResult;
import io.geordi.slos.application.WindowedBurnRateObservation;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.BurnRateEvaluation;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import io.geordi.slos.domain.SloEvaluation;
import io.geordi.slos.domain.SloStatus;
import io.geordi.slos.domain.TimeRange;
import io.geordi.slos.domain.UnavailableReason;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import org.junit.jupiter.api.Test;

class SlosReliabilityAdapterTest {

    private static final Instant NOW = Instant.parse("2026-08-25T18:00:00Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("checkout", null, "production");

    @Test
    void mapsCanonicalAvailableBurnWithoutRecalculatingIt() {
        SlosReliabilityAdapter adapter = new SlosReliabilityAdapter(
                ignored -> evaluation(BurnRateEvaluation.available(
                        new BigDecimal("0.01"), new BigDecimal("0.037"), new BigDecimal("3.7"))),
                this::boundedEvaluation,
                catalog());

        var evidence = adapter.evaluate("checkout-availability");

        assertThat(evidence.sloId()).isEqualTo("checkout-availability");
        assertThat(evidence.service().namespace()).isNull();
        assertThat(evidence.range().from()).isEqualTo(NOW.minusSeconds(300));
        assertThat(evidence.evaluatedAt()).isEqualTo(NOW);
        assertThat(evidence.observedBurnRate()).isEqualByComparingTo("3.7");
        assertThat(evidence.reason()).isNull();
        assertThat(adapter.exists("checkout-availability")).isTrue();
        assertThat(adapter.exists("missing")).isFalse();
        assertThat(adapter.findById("checkout-availability")).get().satisfies(binding -> {
            assertThat(binding.service().name()).isEqualTo("checkout");
            assertThat(binding.service().environment()).isEqualTo("production");
            assertThat(binding.window().value()).isEqualTo("PT5M");
        });
    }

    @Test
    void mapsCanonicalUnavailabilityWithoutInventingZero() {
        SlosReliabilityAdapter adapter = new SlosReliabilityAdapter(
                ignored -> unavailableEvaluation(), this::boundedEvaluation, catalog());

        var evidence = adapter.evaluate("checkout-availability");

        assertThat(evidence.observedBurnRate()).isNull();
        assertThat(evidence.reason()).isEqualTo(AlertUnavailableReason.NO_TRAFFIC);
        assertThat(evidence.service().name()).isEqualTo("checkout");
        assertThat(evidence.range().to()).isEqualTo(NOW);
    }

    @Test
    void translatesAlertsObservationWindowsToBoundedSloEvidenceWithoutChangingConfiguredProvenance() {
        SlosReliabilityAdapter adapter = new SlosReliabilityAdapter(
                ignored -> unavailableEvaluation(),
                this::boundedEvaluation,
                catalog());

        var evidence = adapter.evaluate("checkout-availability", Set.of(
                AlertObservationWindow.PT1H, AlertObservationWindow.PT5M));

        assertThat(evidence.configuredSloWindow()).isEqualTo(io.geordi.alerts.domain.EvaluationWindow.PT5M);
        assertThat(evidence.evaluatedAt()).isEqualTo(NOW);
        assertThat(evidence.observations()).extracting(observation -> observation.observationWindow())
                .containsExactly(AlertObservationWindow.PT5M, AlertObservationWindow.PT1H);
        assertThat(evidence.observation(AlertObservationWindow.PT5M).observedBurnRate())
                .isEqualByComparingTo("3.7");
        assertThat(evidence.observation(AlertObservationWindow.PT1H).reason())
                .isEqualTo(AlertUnavailableReason.NO_TRAFFIC);
    }

    private BoundedWindowedBurnRateResult boundedEvaluation(
            String sloId, BoundedObservationWindowRequest request) {
        assertThat(request.observationWindows()).containsExactly(Duration.ofMinutes(5), Duration.ofHours(1));
        return new BoundedWindowedBurnRateResult(
                sloId,
                SERVICE,
                EvaluationWindow.PT5M,
                NOW,
                List.of(
                        WindowedBurnRateObservation.available(
                                Duration.ofMinutes(5), new TimeRange(NOW.minus(Duration.ofMinutes(5)), NOW), new BigDecimal("3.7")),
                        WindowedBurnRateObservation.unavailable(
                                Duration.ofHours(1), new TimeRange(NOW.minus(Duration.ofHours(1)), NOW),
                                BurnRateUnavailableReason.NO_TRAFFIC)));
    }

    private static SloEvaluation evaluation(BurnRateEvaluation burn) {
        return new SloEvaluation(
                "checkout-availability", SERVICE, SliType.AVAILABILITY, new BigDecimal("0.99"),
                EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW,
                new BigDecimal("0.963"), new BigDecimal("100"), SloStatus.BREACHED, null, burn);
    }

    private static SloEvaluation unavailableEvaluation() {
        return new SloEvaluation(
                "checkout-availability", SERVICE, SliType.AVAILABILITY, new BigDecimal("0.99"),
                EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW,
                null, BigDecimal.ZERO, SloStatus.UNAVAILABLE, UnavailableReason.NO_TRAFFIC,
                BurnRateEvaluation.unavailable(new BigDecimal("0.01"), BurnRateUnavailableReason.NO_TRAFFIC));
    }

    private static SloDefinitionCatalog catalog() {
        SloDefinition definition = new SloDefinition(
                "checkout-availability", "Checkout availability", null, SERVICE, SliType.AVAILABILITY,
                new BigDecimal("0.99"), EvaluationWindow.PT5M, true);
        return new SloDefinitionCatalog() {
            @Override
            public List<SloDefinition> findAll() {
                return List.of(definition);
            }

            @Override
            public Optional<SloDefinition> findById(String id) {
                return definition.id().equals(id) ? Optional.of(definition) : Optional.empty();
            }
        };
    }
}
