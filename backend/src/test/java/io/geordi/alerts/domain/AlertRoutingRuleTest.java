package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertRoutingRuleTest {

    @Test
    void matchesOnlyConfiguredExactDimensionsAndTreatsOmittedFieldsAsWildcards() {
        AlertTransition transition = started("checkout-burn", "commerce", "checkout", "production");
        AlertRoutingPredicate exact = new AlertRoutingPredicate(
                "checkout-burn", "commerce", "checkout", "production", AlertTransitionType.ALERT_STARTED);
        AlertRoutingPredicate wildcards = new AlertRoutingPredicate(null, null, null, null, null);
        AlertRoutingPredicate wrongEnvironment = new AlertRoutingPredicate(
                null, null, null, "staging", null);

        assertThat(exact.matches(transition)).isTrue();
        assertThat(wildcards.matches(transition)).isTrue();
        assertThat(wrongEnvironment.matches(transition)).isFalse();
    }

    @Test
    void requiresTerminalActionDestinationCombinations() {
        AlertRoutingPredicate predicate = new AlertRoutingPredicate(null, null, null, null, null);

        assertThat(new AlertRoutingRule("deliver", predicate, AlertRoutingAction.DELIVER, "primary").destinationId())
                .isEqualTo("primary");
        assertThat(new AlertRoutingRule("suppress", predicate, AlertRoutingAction.SUPPRESS, null).destinationId())
                .isNull();
        assertThatThrownBy(() -> new AlertRoutingRule("invalid", predicate, AlertRoutingAction.DELIVER, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("deliver routing rule destination id is required");
        assertThatThrownBy(() -> new AlertRoutingRule("invalid", predicate, AlertRoutingAction.SUPPRESS, "primary"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("suppress routing rule must not specify a destination id");
    }

    private static AlertTransition started(String policyId, String namespace, String name, String environment) {
        Instant now = Instant.parse("2026-09-01T12:00:00Z");
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE);
        AlertEvaluation evaluation = new AlertEvaluation(
                policyId, "Policy", "slo", condition, AlertEvaluationStatus.CONDITION_MET, null,
                new BurnRateEvidence("slo", new ServiceIdentity(name, namespace, environment), EvaluationWindow.PT5M,
                        new TimeRange(now.minusSeconds(300), now), now, BigDecimal.TEN, null));
        return new AlertTransition(policyId, AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, now, evaluation);
    }
}
