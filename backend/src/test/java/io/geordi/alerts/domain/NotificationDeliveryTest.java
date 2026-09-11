package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class NotificationDeliveryTest {

    private static final Instant OCCURRED_AT = Instant.parse("2026-08-28T18:00:00Z");

    @Test
    void preservesKnownNanosecondCanonicalIdentity() {
        AlertTransition transition = transition(OCCURRED_AT.plusNanos(123456789));
        String expected = "6b652cfbbf4fdda11500ff84bc1772f382bd4f0630c0ffeb3d9f350c0d830cfd";
        assertThat(NotificationDelivery.stableId(transition)).isEqualTo(expected);
        assertThat(AlertTransitionId.from(transition).value()).isEqualTo(expected);
    }

    @Test
    void requiresOneCanonicalTransitionForHistoryAndMatchedDelivery() {
        AlertTransition transition = transition(OCCURRED_AT.plusNanos(123456789));
        NotificationDelivery delivery = NotificationDelivery.pending(
                transition, new NotificationDestination("operations-webhook", "fingerprint"), OCCURRED_AT);
        var intent = new AlertTransitionCommitIntent(AlertHistoryMutation.from(transition),
                new NotificationCommitIntent.Matched(delivery));
        assertThat(intent.disposition().disposition()).isEqualTo(NotificationDisposition.MATCHED);
        assertThatThrownBy(() -> new AlertTransitionCommitIntent(
                AlertHistoryMutation.from(transition(OCCURRED_AT)), new NotificationCommitIntent.Matched(delivery)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThat(new AlertTransitionCommitIntent(AlertHistoryMutation.from(transition),
                NotificationCommitIntent.Suppressed.INSTANCE).disposition().disposition())
                .isEqualTo(NotificationDisposition.SUPPRESSED);
        assertThat(new AlertTransitionCommitIntent(AlertHistoryMutation.from(transition),
                NotificationCommitIntent.Unrouted.INSTANCE).disposition().disposition())
                .isEqualTo(NotificationDisposition.UNROUTED);
    }

    @Test
    void derivesAStableDeliveryIdentityFromTheCanonicalTransition() {
        AlertTransition first = transition(OCCURRED_AT);
        AlertTransition equivalent = transition(OCCURRED_AT);

        NotificationDelivery delivery = NotificationDelivery.pending(
                first, new NotificationDestination("operations-webhook", "fingerprint"), OCCURRED_AT.plusSeconds(1));

        assertThat(delivery.id()).isEqualTo(NotificationDelivery.stableId(equivalent));
        assertThat(delivery.state()).isEqualTo(NotificationDeliveryState.PENDING);
        assertThat(delivery.attempts()).isZero();
        assertThat(delivery.nextAttemptAt()).isEqualTo(OCCURRED_AT.plusSeconds(1));
    }

    @Test
    void rejectsAnIncompleteLeaseOrTerminalState() {
        AlertTransition transition = transition(OCCURRED_AT);
        NotificationDestination destination = new NotificationDestination("operations-webhook", "fingerprint");

        assertThatThrownBy(() -> new NotificationDelivery(
                        "delivery", transition, destination, NotificationDeliveryState.LEASED, 1,
                        OCCURRED_AT, OCCURRED_AT, null, null, null))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new NotificationDelivery(
                        "delivery", transition, destination, NotificationDeliveryState.DELIVERED, 1,
                        OCCURRED_AT, OCCURRED_AT, null, null, null))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static AlertTransition transition(Instant occurredAt) {
        BurnRateEvidence evidence = new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(occurredAt.minusSeconds(300), occurredAt), occurredAt,
                new BigDecimal("3"), null);
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
        return new AlertTransition(
                "checkout-burn", AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, occurredAt, evaluation);
    }
}
