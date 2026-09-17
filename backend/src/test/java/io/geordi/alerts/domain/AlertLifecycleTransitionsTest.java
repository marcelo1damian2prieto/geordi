package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class AlertLifecycleTransitionsTest {

    private static final Instant FIRST = Instant.parse("2026-08-27T12:00:00Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("checkout", "commerce", "production");

    @Test
    void appliesTheCompleteStateTransitionTable() {
        assertDecision(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST),
                AlertLifecycleState.FIRING, AlertTransitionType.ALERT_STARTED);
        assertDecision(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST),
                AlertLifecycleState.INACTIVE, null);
        assertDecision(Optional.empty(), unavailable(FIRST, AlertUnavailableReason.NO_TRAFFIC),
                AlertLifecycleState.INACTIVE, null);

        AlertLifecycle firing = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        assertDecision(Optional.of(firing), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST.plusSeconds(1)),
                AlertLifecycleState.FIRING, null);
        assertDecision(Optional.of(firing), evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1)),
                AlertLifecycleState.INACTIVE, AlertTransitionType.ALERT_RESOLVED);
        assertDecision(Optional.of(firing), unavailable(FIRST.plusSeconds(1), AlertUnavailableReason.METRICS_UNAVAILABLE),
                AlertLifecycleState.FIRING, null);

        AlertLifecycle inactive = apply(
                Optional.of(firing), evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1)));
        assertDecision(Optional.of(inactive), evaluation(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(2)), AlertLifecycleState.INACTIVE, null);
        assertDecision(Optional.of(inactive), unavailable(
                FIRST.plusSeconds(2), AlertUnavailableReason.NO_TRAFFIC), AlertLifecycleState.INACTIVE, null);
    }

    @Test
    void retainsActiveEvidenceAndStartAcrossUnavailableAndDisabledChecks() {
        AlertLifecycle firing = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        AlertEvidence activeEvidence = firing.activeEvidence();
        AlertLifecycle unavailable = apply(
                Optional.of(firing), unavailable(FIRST.plusSeconds(1), AlertUnavailableReason.METRICS_UNAVAILABLE));
        Instant disabledAt = FIRST.plusSeconds(2);
        AlertLifecycle disabled = AlertLifecycleTransitions.apply(
                Optional.of(unavailable), disabled(), disabledAt).current();

        assertThat(disabled.state()).isEqualTo(AlertLifecycleState.FIRING);
        assertThat(disabled.activeEvidence()).isEqualTo(activeEvidence);
        assertThat(disabled.startedAt()).isEqualTo(FIRST);
        assertThat(disabled.lastEvidenceAt()).isEqualTo(FIRST.plusSeconds(1));
        assertThat(disabled.lastProcessedAt()).isEqualTo(disabledAt);
        assertThat(disabled.latestEvaluation().reason()).isEqualTo(AlertUnavailableReason.DISABLED);
    }

    @Test
    void emitsExactlyOneStartAndOneResolutionAcrossRepeatedEvidence() {
        AlertLifecycle first = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        var repeated = AlertLifecycleTransitions.apply(
                Optional.of(first), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST.plusSeconds(1)), null);
        var unavailable = AlertLifecycleTransitions.apply(
                Optional.of(repeated.current()), unavailable(
                        FIRST.plusSeconds(2), AlertUnavailableReason.METRICS_UNAVAILABLE), null);
        var resolution = AlertLifecycleTransitions.apply(
                Optional.of(unavailable.current()), evaluation(
                        AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(3)), null);
        var repeatedResolution = AlertLifecycleTransitions.apply(
                Optional.of(resolution.current()), evaluation(
                        AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(4)), null);

        assertThat(first.latestTransition().type()).isEqualTo(AlertTransitionType.ALERT_STARTED);
        assertThat(repeated.transition()).isNull();
        assertThat(unavailable.transition()).isNull();
        assertThat(resolution.transition().type()).isEqualTo(AlertTransitionType.ALERT_RESOLVED);
        assertThat(repeatedResolution.transition()).isNull();
        assertThat(repeatedResolution.current().latestTransition()).isEqualTo(resolution.transition());
    }

    @Test
    void ignoresOlderAndEqualCanonicalEvidenceWithoutChangingTheRecord() {
        AlertLifecycle firing = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));

        var stale = AlertLifecycleTransitions.apply(
                Optional.of(firing), evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.minusSeconds(1)), null);
        var duplicate = AlertLifecycleTransitions.apply(
                Optional.of(firing), evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST), null);

        assertThat(stale.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.STALE_IGNORED);
        assertThat(duplicate.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.DUPLICATE_IGNORED);
        assertThat(stale.current()).isSameAs(firing);
        assertThat(duplicate.current()).isSameAs(firing);
        assertThat(stale.writeRequired()).isFalse();
        assertThat(duplicate.writeRequired()).isFalse();
    }

    @Test
    void ignoresOlderAndEqualDisabledCommandsByProcessingTime() {
        AlertLifecycle firing = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));

        var stale = AlertLifecycleTransitions.apply(
                Optional.of(firing), disabled(), FIRST.minusSeconds(1));
        var duplicate = AlertLifecycleTransitions.apply(
                Optional.of(firing), disabled(), FIRST);

        assertThat(stale.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.STALE_IGNORED);
        assertThat(duplicate.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.DUPLICATE_IGNORED);
        assertThat(stale.current()).isSameAs(firing);
        assertThat(duplicate.current()).isSameAs(firing);
        assertThat(stale.writeRequired()).isFalse();
        assertThat(duplicate.writeRequired()).isFalse();
    }

    @Test
    void failsClosedWhenImmutablePolicyOrEvidenceBindingChanges() {
        AlertLifecycle firing = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        AlertEvaluation otherCondition = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability",
                new BurnRateAboveCondition(new BigDecimal("3")),
                AlertEvaluationStatus.CONDITION_MET, null, evidence(FIRST.plusSeconds(1), "3", SERVICE));
        AlertEvaluation otherService = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(),
                AlertEvaluationStatus.CONDITION_MET, null,
                evidence(FIRST.plusSeconds(1), "3", new ServiceIdentity("orders", null, "production")));

        assertThatThrownBy(() -> AlertLifecycleTransitions.apply(Optional.of(firing), otherCondition, null))
                .isInstanceOf(AlertLifecycleBindingMismatchException.class);
        assertThatThrownBy(() -> AlertLifecycleTransitions.apply(Optional.of(firing), otherService, null))
                .isInstanceOf(AlertLifecycleBindingMismatchException.class);
    }

    @Test
    void retainsCompleteMultiwindowActiveEvidenceAcrossFreezeAndResolvesNormally() {
        MultiwindowBurnRateCondition condition = multiwindowCondition();
        AlertEvaluation firingEvaluation = multiwindowEvaluation(
                condition, FIRST, "3", "3", "1", "3", null);
        AlertLifecycle firing = apply(Optional.empty(), firingEvaluation);
        MultiwindowBurnRateEvidence active = (MultiwindowBurnRateEvidence) firing.activeEvidence();

        AlertEvaluation unavailable = multiwindowEvaluation(
                condition, FIRST.plusSeconds(1), "3", null, "1", "3",
                AlertUnavailableReason.MISSING_REQUEST_COUNT);
        AlertLifecycle frozen = apply(Optional.of(firing), unavailable);
        AlertEvaluation resolving = multiwindowEvaluation(
                condition, FIRST.plusSeconds(2), "1", "3", "1", "3", null);
        var resolved = AlertLifecycleTransitions.apply(Optional.of(frozen), resolving, null);

        assertThat(active.observations()).hasSize(4);
        assertThat(frozen.state()).isEqualTo(AlertLifecycleState.FIRING);
        assertThat(frozen.activeEvidence()).isSameAs(active);
        assertThat(((MultiwindowBurnRateEvidence) frozen.latestEvaluation().evidence()).observations()).hasSize(4);
        assertThat(frozen.latestEvaluation().bandResults()).extracting(BurnRateBandResult::outcome)
                .containsExactly(BurnRateBandOutcome.UNAVAILABLE, BurnRateBandOutcome.NOT_MET);
        assertThat(resolved.current().state()).isEqualTo(AlertLifecycleState.INACTIVE);
        assertThat(resolved.transition().type()).isEqualTo(AlertTransitionType.ALERT_RESOLVED);
    }

    @Test
    void rejectsChangingALegacyLifecycleToMultiwindowUnderTheSamePolicyId() {
        AlertLifecycle legacy = apply(Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        AlertEvaluation multiwindow = multiwindowEvaluation(
                multiwindowCondition(), FIRST.plusSeconds(1), "3", "3", "1", "3", null);

        assertThatThrownBy(() -> AlertLifecycleTransitions.apply(Optional.of(legacy), multiwindow, null))
                .isInstanceOf(AlertLifecycleBindingMismatchException.class);
    }

    private static void assertDecision(
            Optional<AlertLifecycle> previous,
            AlertEvaluation evaluation,
            AlertLifecycleState state,
            AlertTransitionType transitionType) {
        var decision = AlertLifecycleTransitions.apply(previous, evaluation, FIRST.plusSeconds(10));
        assertThat(decision.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.APPLIED);
        assertThat(decision.current().state()).isEqualTo(state);
        if (transitionType == null) {
            assertThat(decision.transition()).isNull();
        } else {
            assertThat(decision.transition().type()).isEqualTo(transitionType);
            assertThat(decision.transition().occurredAt()).isEqualTo(evaluation.evidence().evaluatedAt());
        }
    }

    private static AlertLifecycle apply(Optional<AlertLifecycle> previous, AlertEvaluation evaluation) {
        return AlertLifecycleTransitions.apply(previous, evaluation, FIRST.plusSeconds(10)).current();
    }

    private static AlertEvaluation evaluation(AlertEvaluationStatus status, Instant evaluatedAt) {
        String burnRate = status == AlertEvaluationStatus.CONDITION_MET ? "3" : "0.5";
        return new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(), status, null,
                evidence(evaluatedAt, burnRate, SERVICE));
    }

    private static AlertEvaluation unavailable(Instant evaluatedAt, AlertUnavailableReason reason) {
        return new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(),
                AlertEvaluationStatus.UNAVAILABLE, reason,
                new BurnRateEvidence(
                        "checkout-availability", SERVICE, EvaluationWindow.PT5M,
                        new TimeRange(evaluatedAt.minusSeconds(300), evaluatedAt), evaluatedAt, null, reason));
    }

    private static AlertEvaluation disabled() {
        return new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(),
                AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.DISABLED, null);
    }

    private static BurnRateEvidence evidence(Instant evaluatedAt, String burnRate, ServiceIdentity service) {
        return new BurnRateEvidence(
                "checkout-availability", service, EvaluationWindow.PT5M,
                new TimeRange(evaluatedAt.minusSeconds(300), evaluatedAt), evaluatedAt,
                new BigDecimal(burnRate), null);
    }

    private static AlertCondition condition() {
        return new BurnRateAboveCondition(new BigDecimal("2"));
    }

    private static MultiwindowBurnRateCondition multiwindowCondition() {
        return new MultiwindowBurnRateCondition(List.of(
                new BurnRateBand(
                        AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("2")),
                new BurnRateBand(
                        AlertObservationWindow.PT6H, AlertObservationWindow.PT30M, new BigDecimal("2"))));
    }

    private static AlertEvaluation multiwindowEvaluation(
            MultiwindowBurnRateCondition condition,
            Instant evaluatedAt,
            String oneHour,
            String fiveMinutes,
            String sixHours,
            String thirtyMinutes,
            AlertUnavailableReason unavailableReason) {
        MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                "checkout-availability",
                SERVICE,
                EvaluationWindow.PT5M,
                evaluatedAt,
                condition.observationWindows(),
                List.of(
                        observation(AlertObservationWindow.PT1H, evaluatedAt, oneHour, null),
                        observation(
                                AlertObservationWindow.PT5M,
                                evaluatedAt,
                                fiveMinutes,
                                fiveMinutes == null ? unavailableReason : null),
                        observation(AlertObservationWindow.PT6H, evaluatedAt, sixHours, null),
                        observation(AlertObservationWindow.PT30M, evaluatedAt, thirtyMinutes, null)));
        AlertEvaluationStatus status = condition.evaluateStatus(evidence);
        return new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition,
                status,
                status == AlertEvaluationStatus.UNAVAILABLE
                        ? AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE : null,
                evidence);
    }

    private static WindowBurnRateObservation observation(
            AlertObservationWindow window,
            Instant evaluatedAt,
            String value,
            AlertUnavailableReason unavailableReason) {
        return new WindowBurnRateObservation(
                window,
                new TimeRange(evaluatedAt.minus(window.duration()), evaluatedAt),
                value == null ? null : new BigDecimal(value),
                unavailableReason);
    }
}
