package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertsDomainTest {

    @Test
    void acceptsZeroAndFinitePublicNumberSafeThresholds() {
        AlertCondition zero = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ZERO);
        AlertCondition positive = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2.5"));

        assertThat(zero.threshold()).isEqualByComparingTo("0");
        assertThat(positive.threshold()).isEqualByComparingTo("2.5");
    }

    @Test
    void rejectsNegativeOverflowingAndPositiveUnderflowingThresholds() {
        assertThatThrownBy(() -> condition("-0.01")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> condition("1E+309")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> condition("1E-325")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void validatesAndNormalizesPolicyFields() {
        AlertPolicy policy = new AlertPolicy(
                "checkout-burn", " Checkout burn ", " Current burn ", true,
                "checkout-availability", condition("2"));

        assertThat(policy.name()).isEqualTo("Checkout burn");
        assertThat(policy.description()).isEqualTo("Current burn");
        assertThat(policy.sloId()).isEqualTo("checkout-availability");
        assertThatThrownBy(() -> new AlertPolicy(
                "Bad Id", "Name", null, true, "slo", condition("1")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new AlertPolicy(
                "policy", "Name", null, true, "Bad SLO", condition("1")))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void rejectsContradictoryUnavailableEvaluations() {
        BurnRateEvidence available = evidence("slo", BigDecimal.ONE, null);
        BurnRateEvidence metricsUnavailable = evidence(
                "slo", null, AlertUnavailableReason.METRICS_UNAVAILABLE);

        assertThatThrownBy(() -> evaluation(
                AlertUnavailableReason.METRICS_UNAVAILABLE, available))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> evaluation(
                AlertUnavailableReason.NO_TRAFFIC, metricsUnavailable))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> evaluation(
                AlertUnavailableReason.DISABLED, metricsUnavailable))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new AlertEvaluation(
                "policy", "Policy", "other-slo", condition("1"),
                AlertEvaluationStatus.UNAVAILABLE,
                AlertUnavailableReason.METRICS_UNAVAILABLE,
                metricsUnavailable))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static AlertEvaluation evaluation(
            AlertUnavailableReason reason, BurnRateEvidence evidence) {
        return new AlertEvaluation(
                "policy", "Policy", "slo", condition("1"),
                AlertEvaluationStatus.UNAVAILABLE, reason, evidence);
    }

    private static BurnRateEvidence evidence(
            String sloId, BigDecimal burnRate, AlertUnavailableReason reason) {
        Instant to = Instant.parse("2026-08-25T12:00:00Z");
        EvaluationWindow window = EvaluationWindow.PT5M;
        return new BurnRateEvidence(
                sloId,
                new ServiceIdentity("service", "namespace", "development"),
                window,
                new TimeRange(to.minus(window.duration()), to),
                to,
                burnRate,
                reason);
    }

    private static AlertCondition condition(String threshold) {
        return new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal(threshold));
    }
}
