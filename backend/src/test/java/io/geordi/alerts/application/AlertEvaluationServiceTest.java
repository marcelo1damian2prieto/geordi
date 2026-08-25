package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
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
            if (reason == AlertUnavailableReason.DISABLED) {
                continue;
            }
            AlertEvaluationService service = service(policy(true, "2"), ignored -> unavailable(reason));

            var result = service.evaluate("checkout-burn");

            assertThat(result.status()).isEqualTo(AlertEvaluationStatus.UNAVAILABLE);
            assertThat(result.reason()).isEqualTo(reason);
            assertThat(result.evidence()).isNotNull();
            assertThat(result.evidence().service()).isEqualTo(SERVICE);
            assertThat(result.evidence().range()).isEqualTo(RANGE);
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
        return new AlertPolicy(
                "checkout-burn", "Checkout burn", null, enabled, "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal(threshold)));
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
}
