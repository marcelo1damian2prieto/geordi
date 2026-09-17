package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.BurnRateBandOutcome;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class AlertEvaluationServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-25T18:00:00Z");
    private static final TimeRange RANGE = new TimeRange(NOW.minusSeconds(300), NOW);
    private static final ServiceIdentity SERVICE = new ServiceIdentity("checkout", "commerce", "production");

    @Test
    void usesInclusiveBurnRateComparison() {
        assertStatus("1.99", "2", AlertEvaluationStatus.CONDITION_NOT_MET);
        assertStatus("2", "2", AlertEvaluationStatus.CONDITION_MET);
        assertStatus("2.01", "2", AlertEvaluationStatus.CONDITION_MET);
    }

    @Test
    void treatsValidZeroAsEvidenceAndAllowsZeroThreshold() {
        assertStatus("0", "1", AlertEvaluationStatus.CONDITION_NOT_MET);
        assertStatus("0", "0", AlertEvaluationStatus.CONDITION_MET);
    }

    @Test
    void propagatesEveryUnavailableReasonWithItsExactEvidenceContext() {
        for (AlertUnavailableReason reason : AlertUnavailableReason.values()) {
            if (reason == AlertUnavailableReason.DISABLED
                    || reason == AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE) {
                continue;
            }
            AlertEvaluationService service = service(policy(true, "2"), ignored -> unavailable(reason));

            var result = service.evaluate("checkout-burn");

            assertThat(result.status()).isEqualTo(AlertEvaluationStatus.UNAVAILABLE);
            assertThat(result.reason()).isEqualTo(reason);
            assertThat(result.evidence()).isNotNull();
            assertThat(result.evidence().service()).isEqualTo(SERVICE);
            assertThat((BurnRateEvidence) result.evidence()).satisfies(evidence ->
                    assertThat(evidence.range()).isEqualTo(RANGE));
            assertThat(result.evidence().evaluatedAt()).isEqualTo(NOW);
        }
    }

    @Test
    void disabledPolicyDoesNotCallTheSloBoundaryOrFabricateEvidence() {
        AtomicInteger calls = new AtomicInteger();
        AlertEvaluationService service = service(policy(false, "2"), ignored -> {
            calls.incrementAndGet();
            return available("3");
        });

        var result = service.evaluate("checkout-burn");

        assertThat(result.status()).isEqualTo(AlertEvaluationStatus.UNAVAILABLE);
        assertThat(result.reason()).isEqualTo(AlertUnavailableReason.DISABLED);
        assertThat(result.evidence()).isNull();
        assertThat(calls).hasValue(0);
    }

    @Test
    void rejectsEvidenceForAnotherSloInsteadOfEvaluatingTheWrongTelemetry() {
        AlertEvaluationService service = service(policy(true, "2"), ignored -> new BurnRateEvidence(
                "another-slo", SERVICE, EvaluationWindow.PT5M, RANGE, NOW, new BigDecimal("3"), null));

        assertThatThrownBy(() -> service.evaluate("checkout-burn"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void requestsTheExactWindowUnionAndRetainsAllEvidenceForADecisiveMultiwindowResult() {
        MultiwindowBurnRateCondition condition = multiwindowCondition();
        MultiwindowBurnRateEvidence evidence = aggregate(
                observation(AlertObservationWindow.PT1H, "3", null),
                observation(AlertObservationWindow.PT5M, "1", null),
                observation(AlertObservationWindow.PT6H, "3", null),
                observation(AlertObservationWindow.PT30M, "2", null));
        AtomicReference<Set<AlertObservationWindow>> requested = new AtomicReference<>();
        AlertEvaluationService service = service(
                policy(true, condition), multiwindowPort(requested, evidence));

        var result = service.evaluate("checkout-burn");

        assertThat(requested.get()).containsExactly(
                AlertObservationWindow.PT5M,
                AlertObservationWindow.PT30M,
                AlertObservationWindow.PT1H,
                AlertObservationWindow.PT6H);
        assertThat(result.status()).isEqualTo(AlertEvaluationStatus.CONDITION_MET);
        assertThat(result.reason()).isNull();
        assertThat(result.evidence()).isSameAs(evidence);
        assertThat(result.bandResults()).extracting(value -> value.outcome())
                .containsExactly(BurnRateBandOutcome.NOT_MET, BurnRateBandOutcome.MET);
    }

    @Test
    void appliesStrongLogicToUnavailableConstituentsWithoutDiscardingThem() {
        MultiwindowBurnRateCondition condition = multiwindowCondition();
        MultiwindowBurnRateEvidence decisiveFalse = aggregate(
                observation(AlertObservationWindow.PT1H, null, AlertUnavailableReason.METRICS_UNAVAILABLE),
                observation(AlertObservationWindow.PT5M, "1", null),
                observation(AlertObservationWindow.PT6H, "1", null),
                observation(AlertObservationWindow.PT30M, "3", null));
        MultiwindowBurnRateEvidence unavailable = aggregate(
                observation(AlertObservationWindow.PT1H, "3", null),
                observation(AlertObservationWindow.PT5M, null, AlertUnavailableReason.MISSING_REQUEST_COUNT),
                observation(AlertObservationWindow.PT6H, "1", null),
                observation(AlertObservationWindow.PT30M, "3", null));

        var falseResult = service(policy(true, condition), multiwindowPort(null, decisiveFalse))
                .evaluate("checkout-burn");
        var unavailableResult = service(policy(true, condition), multiwindowPort(null, unavailable))
                .evaluate("checkout-burn");

        assertThat(falseResult.status()).isEqualTo(AlertEvaluationStatus.CONDITION_NOT_MET);
        assertThat(falseResult.reason()).isNull();
        assertThat(((MultiwindowBurnRateEvidence) falseResult.evidence()).observations()).hasSize(4);
        assertThat(unavailableResult.status()).isEqualTo(AlertEvaluationStatus.UNAVAILABLE);
        assertThat(unavailableResult.reason())
                .isEqualTo(AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE);
        assertThat(unavailableResult.bandResults()).extracting(value -> value.outcome())
                .containsExactly(BurnRateBandOutcome.UNAVAILABLE, BurnRateBandOutcome.NOT_MET);
    }

    @Test
    void disabledMultiwindowPolicyCallsNeitherEvidencePath() {
        AtomicInteger calls = new AtomicInteger();
        BurnRateEvidencePort port = new BurnRateEvidencePort() {
            @Override
            public BurnRateEvidence evaluate(String sloId) {
                calls.incrementAndGet();
                return available("3");
            }

            @Override
            public MultiwindowBurnRateEvidence evaluate(
                    String sloId, Set<AlertObservationWindow> observationWindows) {
                calls.incrementAndGet();
                return aggregate(
                        observation(AlertObservationWindow.PT1H, "3", null),
                        observation(AlertObservationWindow.PT5M, "3", null),
                        observation(AlertObservationWindow.PT6H, "3", null),
                        observation(AlertObservationWindow.PT30M, "3", null));
            }
        };

        AlertEvaluation result = service(policy(false, multiwindowCondition()), port)
                .evaluate("checkout-burn");

        assertThat(calls).hasValue(0);
        assertThat(result.status()).isEqualTo(AlertEvaluationStatus.UNAVAILABLE);
        assertThat(result.reason()).isEqualTo(AlertUnavailableReason.DISABLED);
        assertThat(result.evidence()).isNull();
    }

    private static void assertStatus(String observed, String threshold, AlertEvaluationStatus expected) {
        AlertEvaluationService service = service(policy(true, threshold), ignored -> available(observed));
        assertThat(service.evaluate("checkout-burn").status()).isEqualTo(expected);
    }

    private static AlertEvaluationService service(AlertPolicy policy, BurnRateEvidencePort evidencePort) {
        AlertPolicyCatalog catalog = new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(policy);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return policy.id().equals(id) ? Optional.of(policy) : Optional.empty();
            }
        };
        return new AlertEvaluationService(catalog, evidencePort);
    }

    private static AlertPolicy policy(boolean enabled, String threshold) {
        return policy(enabled, new BurnRateAboveCondition(new BigDecimal(threshold)));
    }

    private static AlertPolicy policy(boolean enabled, io.geordi.alerts.domain.AlertCondition condition) {
        return new AlertPolicy(
                "checkout-burn", "Checkout burn", null, enabled, "checkout-availability",
                condition);
    }

    private static BurnRateEvidence available(String value) {
        return new BurnRateEvidence(
                "checkout-availability", SERVICE, EvaluationWindow.PT5M, RANGE, NOW,
                new BigDecimal(value), null);
    }

    private static BurnRateEvidence unavailable(AlertUnavailableReason reason) {
        return new BurnRateEvidence(
                "checkout-availability", SERVICE, EvaluationWindow.PT5M, RANGE, NOW, null, reason);
    }

    private static MultiwindowBurnRateCondition multiwindowCondition() {
        return new MultiwindowBurnRateCondition(List.of(
                new BurnRateBand(
                        AlertObservationWindow.PT6H, AlertObservationWindow.PT30M, new BigDecimal("2")),
                new BurnRateBand(
                        AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("2"))));
    }

    private static BurnRateEvidencePort multiwindowPort(
            AtomicReference<Set<AlertObservationWindow>> requested,
            MultiwindowBurnRateEvidence evidence) {
        return new BurnRateEvidencePort() {
            @Override
            public BurnRateEvidence evaluate(String sloId) {
                throw new AssertionError("multiwindow policy must not use scalar evaluation");
            }

            @Override
            public MultiwindowBurnRateEvidence evaluate(
                    String sloId, Set<AlertObservationWindow> observationWindows) {
                if (requested != null) {
                    requested.set(observationWindows);
                }
                return evidence;
            }
        };
    }

    private static MultiwindowBurnRateEvidence aggregate(WindowBurnRateObservation... observations) {
        MultiwindowBurnRateCondition condition = multiwindowCondition();
        return MultiwindowBurnRateEvidence.of(
                "checkout-availability", SERVICE, EvaluationWindow.PT5M, NOW,
                condition.observationWindows(), List.of(observations));
    }

    private static WindowBurnRateObservation observation(
            AlertObservationWindow window, String value, AlertUnavailableReason reason) {
        return new WindowBurnRateObservation(
                window, new TimeRange(NOW.minus(window.duration()), NOW),
                value == null ? null : new BigDecimal(value), reason);
    }
}
