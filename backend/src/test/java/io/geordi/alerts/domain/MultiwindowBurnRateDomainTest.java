package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

class MultiwindowBurnRateDomainTest {

    private static final Instant EVALUATED_AT = Instant.parse("2026-09-14T18:00:00Z");
    private static final ServiceIdentity SERVICE =
            new ServiceIdentity("checkout", "commerce", "production");
    private static final BigDecimal THRESHOLD = new BigDecimal("2");

    @Test
    void closesAndCanonicalizesTheSupportedConditionModel() {
        BurnRateBand slow = new BurnRateBand(
                AlertObservationWindow.PT6H, AlertObservationWindow.PT30M, new BigDecimal("6.00"));
        BurnRateBand fast = new BurnRateBand(
                AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("14.400"));

        MultiwindowBurnRateCondition condition = new MultiwindowBurnRateCondition(List.of(slow, fast));

        assertThat(AlertCondition.class.isSealed()).isTrue();
        assertThat(condition.bands()).containsExactly(fast, slow);
        assertThat(condition.bands().get(0).threshold()).isEqualTo(new BigDecimal("14.4"));
        assertThat(condition.bands().get(1).threshold()).isEqualTo(new BigDecimal("6"));
        assertThat(condition.observationWindows()).containsExactly(
                AlertObservationWindow.PT5M,
                AlertObservationWindow.PT30M,
                AlertObservationWindow.PT1H,
                AlertObservationWindow.PT6H);
        assertThat(new BurnRateAboveCondition(new BigDecimal("6.0")))
                .isEqualTo(new BurnRateAboveCondition(new BigDecimal("6.00")));
    }

    @Test
    void rejectsUnsupportedDuplicateOrUnboundedBandSetsAndInvalidThresholds() {
        BurnRateBand fast = band(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M);
        BurnRateBand slow = band(AlertObservationWindow.PT6H, AlertObservationWindow.PT30M);

        assertThatThrownBy(() -> band(AlertObservationWindow.PT1H, AlertObservationWindow.PT30M))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new MultiwindowBurnRateCondition(List.of()))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new MultiwindowBurnRateCondition(List.of(fast, fast)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new MultiwindowBurnRateCondition(List.of(fast, slow, fast)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new BurnRateBand(
                AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("-1")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new BurnRateBand(
                AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("1E+309")))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @ParameterizedTest
    @MethodSource("strongAndCases")
    void evaluatesEveryStrongAndTruthTableRow(
            ObservationValue longValue,
            ObservationValue shortValue,
            BurnRateBandOutcome expected) {
        MultiwindowBurnRateCondition condition = new MultiwindowBurnRateCondition(List.of(
                band(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M)));
        MultiwindowBurnRateEvidence evidence = evidence(condition.observationWindows(), List.of(
                observation(AlertObservationWindow.PT1H, longValue),
                observation(AlertObservationWindow.PT5M, shortValue)));

        assertThat(condition.evaluate(evidence)).singleElement().satisfies(result -> {
            assertThat(result.outcome()).isEqualTo(expected);
            assertThat(result.longObservation()).isEqualTo(evidence.observation(AlertObservationWindow.PT1H));
            assertThat(result.shortObservation()).isEqualTo(evidence.observation(AlertObservationWindow.PT5M));
        });
    }

    @ParameterizedTest
    @MethodSource("strongOrCases")
    void evaluatesStrongOrAcrossCanonicalBands(
            BurnRateBandOutcome fastOutcome,
            BurnRateBandOutcome slowOutcome,
            AlertEvaluationStatus expected) {
        MultiwindowBurnRateCondition condition = twoBandCondition();
        MultiwindowBurnRateEvidence evidence = evidenceForOutcomes(fastOutcome, slowOutcome);

        assertThat(condition.evaluateStatus(evidence)).isEqualTo(expected);
    }

    @Test
    void enforcesCompleteCanonicalAggregateEvidence() {
        MultiwindowBurnRateCondition condition = twoBandCondition();
        List<WindowBurnRateObservation> reverse = List.of(
                observation(AlertObservationWindow.PT6H, ObservationValue.TRUE),
                observation(AlertObservationWindow.PT1H, ObservationValue.TRUE),
                observation(AlertObservationWindow.PT30M, ObservationValue.TRUE),
                observation(AlertObservationWindow.PT5M, ObservationValue.TRUE));

        MultiwindowBurnRateEvidence aggregate = evidence(condition.observationWindows(), reverse);

        assertThat(aggregate.observations()).extracting(WindowBurnRateObservation::observationWindow)
                .containsExactly(
                        AlertObservationWindow.PT5M,
                        AlertObservationWindow.PT30M,
                        AlertObservationWindow.PT1H,
                        AlertObservationWindow.PT6H);
        assertThatThrownBy(() -> evidence(condition.observationWindows(), reverse.subList(0, 3)))
                .isInstanceOf(IllegalArgumentException.class);

        List<WindowBurnRateObservation> duplicate = new ArrayList<>(reverse);
        duplicate.set(3, observation(AlertObservationWindow.PT30M, ObservationValue.FALSE));
        assertThatThrownBy(() -> evidence(condition.observationWindows(), duplicate))
                .isInstanceOf(IllegalArgumentException.class);

        WindowBurnRateObservation stale = new WindowBurnRateObservation(
                AlertObservationWindow.PT5M,
                new TimeRange(EVALUATED_AT.minusSeconds(301), EVALUATED_AT.minusSeconds(1)),
                BigDecimal.ONE,
                null);
        assertThatThrownBy(() -> evidence(
                EnumSet.of(AlertObservationWindow.PT5M, AlertObservationWindow.PT1H),
                List.of(stale, observation(AlertObservationWindow.PT1H, ObservationValue.TRUE))))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void acceptsPt30mOnlyAsAnAlertObservationWindow() {
        BurnRateBand band = band(AlertObservationWindow.PT6H, AlertObservationWindow.PT30M);

        assertThat(band.shortWindow()).isEqualTo(AlertObservationWindow.PT30M);
        assertThat(AlertObservationWindow.from(java.time.Duration.ofMinutes(30)))
                .isEqualTo(AlertObservationWindow.PT30M);
        assertThatThrownBy(() -> EvaluationWindow.valueOf("PT30M"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsContradictoryMultiwindowEvaluationStatesAndAggregateReasonsOnLeaves() {
        MultiwindowBurnRateCondition condition = new MultiwindowBurnRateCondition(List.of(
                band(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M)));
        MultiwindowBurnRateEvidence met = evidenceFor(condition, BurnRateBandOutcome.MET);
        MultiwindowBurnRateEvidence unavailable = evidenceFor(condition, BurnRateBandOutcome.UNAVAILABLE);

        assertThatThrownBy(() -> new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition,
                AlertEvaluationStatus.CONDITION_NOT_MET, null, met))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition,
                AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.METRICS_UNAVAILABLE, unavailable))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new WindowBurnRateObservation(
                AlertObservationWindow.PT5M,
                range(AlertObservationWindow.PT5M),
                null,
                AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static Stream<Arguments> strongAndCases() {
        return Stream.of(
                Arguments.of(ObservationValue.TRUE, ObservationValue.TRUE, BurnRateBandOutcome.MET),
                Arguments.of(ObservationValue.TRUE, ObservationValue.FALSE, BurnRateBandOutcome.NOT_MET),
                Arguments.of(ObservationValue.FALSE, ObservationValue.TRUE, BurnRateBandOutcome.NOT_MET),
                Arguments.of(ObservationValue.FALSE, ObservationValue.FALSE, BurnRateBandOutcome.NOT_MET),
                Arguments.of(ObservationValue.FALSE, ObservationValue.UNAVAILABLE, BurnRateBandOutcome.NOT_MET),
                Arguments.of(ObservationValue.UNAVAILABLE, ObservationValue.FALSE, BurnRateBandOutcome.NOT_MET),
                Arguments.of(ObservationValue.TRUE, ObservationValue.UNAVAILABLE, BurnRateBandOutcome.UNAVAILABLE),
                Arguments.of(ObservationValue.UNAVAILABLE, ObservationValue.TRUE, BurnRateBandOutcome.UNAVAILABLE),
                Arguments.of(ObservationValue.UNAVAILABLE, ObservationValue.UNAVAILABLE,
                        BurnRateBandOutcome.UNAVAILABLE));
    }

    private static Stream<Arguments> strongOrCases() {
        return Stream.of(
                Arguments.of(BurnRateBandOutcome.MET, BurnRateBandOutcome.MET,
                        AlertEvaluationStatus.CONDITION_MET),
                Arguments.of(BurnRateBandOutcome.MET, BurnRateBandOutcome.NOT_MET,
                        AlertEvaluationStatus.CONDITION_MET),
                Arguments.of(BurnRateBandOutcome.MET, BurnRateBandOutcome.UNAVAILABLE,
                        AlertEvaluationStatus.CONDITION_MET),
                Arguments.of(BurnRateBandOutcome.NOT_MET, BurnRateBandOutcome.MET,
                        AlertEvaluationStatus.CONDITION_MET),
                Arguments.of(BurnRateBandOutcome.NOT_MET, BurnRateBandOutcome.NOT_MET,
                        AlertEvaluationStatus.CONDITION_NOT_MET),
                Arguments.of(BurnRateBandOutcome.NOT_MET, BurnRateBandOutcome.UNAVAILABLE,
                        AlertEvaluationStatus.UNAVAILABLE),
                Arguments.of(BurnRateBandOutcome.UNAVAILABLE, BurnRateBandOutcome.MET,
                        AlertEvaluationStatus.CONDITION_MET),
                Arguments.of(BurnRateBandOutcome.UNAVAILABLE, BurnRateBandOutcome.NOT_MET,
                        AlertEvaluationStatus.UNAVAILABLE),
                Arguments.of(BurnRateBandOutcome.UNAVAILABLE, BurnRateBandOutcome.UNAVAILABLE,
                        AlertEvaluationStatus.UNAVAILABLE));
    }

    private static MultiwindowBurnRateCondition twoBandCondition() {
        return new MultiwindowBurnRateCondition(List.of(
                band(AlertObservationWindow.PT6H, AlertObservationWindow.PT30M),
                band(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M)));
    }

    private static BurnRateBand band(
            AlertObservationWindow longWindow, AlertObservationWindow shortWindow) {
        return new BurnRateBand(longWindow, shortWindow, THRESHOLD);
    }

    private static MultiwindowBurnRateEvidence evidenceForOutcomes(
            BurnRateBandOutcome fast, BurnRateBandOutcome slow) {
        MultiwindowBurnRateCondition condition = twoBandCondition();
        List<WindowBurnRateObservation> observations = new ArrayList<>();
        observations.addAll(observationsFor(
                AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, fast));
        observations.addAll(observationsFor(
                AlertObservationWindow.PT6H, AlertObservationWindow.PT30M, slow));
        return evidence(condition.observationWindows(), observations);
    }

    private static MultiwindowBurnRateEvidence evidenceFor(
            MultiwindowBurnRateCondition condition, BurnRateBandOutcome outcome) {
        BurnRateBand band = condition.bands().getFirst();
        return evidence(condition.observationWindows(), observationsFor(
                band.longWindow(), band.shortWindow(), outcome));
    }

    private static List<WindowBurnRateObservation> observationsFor(
            AlertObservationWindow longWindow,
            AlertObservationWindow shortWindow,
            BurnRateBandOutcome outcome) {
        return switch (outcome) {
            case MET -> List.of(
                    observation(longWindow, ObservationValue.TRUE),
                    observation(shortWindow, ObservationValue.TRUE));
            case NOT_MET -> List.of(
                    observation(longWindow, ObservationValue.TRUE),
                    observation(shortWindow, ObservationValue.FALSE));
            case UNAVAILABLE -> List.of(
                    observation(longWindow, ObservationValue.TRUE),
                    observation(shortWindow, ObservationValue.UNAVAILABLE));
        };
    }

    private static MultiwindowBurnRateEvidence evidence(
            Set<AlertObservationWindow> requested,
            List<WindowBurnRateObservation> observations) {
        return MultiwindowBurnRateEvidence.of(
                "checkout-availability",
                SERVICE,
                EvaluationWindow.PT5M,
                EVALUATED_AT,
                requested,
                observations);
    }

    private static WindowBurnRateObservation observation(
            AlertObservationWindow window, ObservationValue value) {
        return switch (value) {
            case TRUE -> new WindowBurnRateObservation(window, range(window), THRESHOLD, null);
            case FALSE -> new WindowBurnRateObservation(window, range(window), BigDecimal.ONE, null);
            case UNAVAILABLE -> new WindowBurnRateObservation(
                    window, range(window), null, AlertUnavailableReason.METRICS_UNAVAILABLE);
        };
    }

    private static TimeRange range(AlertObservationWindow window) {
        return new TimeRange(EVALUATED_AT.minus(window.duration()), EVALUATED_AT);
    }

    private enum ObservationValue {
        TRUE,
        FALSE,
        UNAVAILABLE
    }
}
