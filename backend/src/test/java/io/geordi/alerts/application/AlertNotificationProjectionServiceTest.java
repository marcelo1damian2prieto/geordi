package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.domain.*;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

class AlertNotificationProjectionServiceTest {
    private static final Instant TIME = Instant.parse("2026-08-28T18:00:00.999999999Z");
    private static final AlertTransitionRecord RECORD = record(TIME);

    @Test
    void preservesAbsentDispositionAndBatchesBothCanonicalTransitions() {
        AtomicInteger calls = new AtomicInteger();
        var second = record(TIME.plusSeconds(1));
        var service = new AlertNotificationProjectionService(ids -> {
            calls.incrementAndGet();
            assertThat(ids).containsExactly(RECORD.id(), second.id());
            return List.of();
        });
        assertThat(service.project(List.of(RECORD, second))).allSatisfy(detail -> {
            assertThat(detail.notification().disposition()).isEqualTo(AlertNotificationStatus.Disposition.NOT_RECORDED);
            assertThat(detail.notification().delivery()).isNull();
        });
        assertThat(calls).hasValue(1);
    }

    @ParameterizedTest
    @EnumSource(NotificationDeliveryState.class)
    void projectsAllRealLegacyDeliveryStatesAndMasksTimestamps(NotificationDeliveryState state) {
        var delivery = delivery(state);
        var actual = project(null, delivery);
        assertThat(actual.disposition()).isEqualTo(AlertNotificationStatus.Disposition.NOT_RECORDED);
        assertThat(actual.delivery().state()).isEqualTo(state);
        assertThat(actual.delivery().attempts()).isEqualTo(2);
        assertThat(actual.delivery().createdAt()).isEqualTo(TIME);
        assertThat(actual.delivery().nextAttemptAt()).isEqualTo(state == NotificationDeliveryState.PENDING ? TIME : null);
        assertThat(actual.delivery().completedAt()).isEqualTo(delivery.completedAt());
        assertThat(project(NotificationDisposition.MATCHED, delivery).disposition())
                .isEqualTo(AlertNotificationStatus.Disposition.MATCHED);
    }

    @Test
    void projectsNonMatchedDecisionsWithoutDelivery() {
        assertThat(project(NotificationDisposition.SUPPRESSED, null).disposition())
                .isEqualTo(AlertNotificationStatus.Disposition.SUPPRESSED);
        assertThat(project(NotificationDisposition.UNROUTED, null).disposition())
                .isEqualTo(AlertNotificationStatus.Disposition.UNROUTED);
    }

    @Test
    void rejectsMissingMatchedAndUnexpectedNonMatchedDelivery() {
        assertFailure(NotificationDisposition.MATCHED, null,
                AlertNotificationIntegrityException.Reason.MATCHED_DELIVERY_MISSING);
        for (var disposition : List.of(NotificationDisposition.SUPPRESSED, NotificationDisposition.UNROUTED)) {
            assertFailure(disposition, delivery(NotificationDeliveryState.PENDING),
                    AlertNotificationIntegrityException.Reason.UNEXPECTED_DELIVERY);
        }
    }

    @Test
    void rejectsIdentityOrCanonicalPayloadMismatchEvenForLegacyRows() {
        assertFailure(null, new AlertNotificationEvidence.Delivery("wrong", RECORD.transition(),
                NotificationDeliveryState.PENDING, 0, TIME, TIME, null),
                AlertNotificationIntegrityException.Reason.CORRELATION_INVALID);
        assertFailure(null, new AlertNotificationEvidence.Delivery(RECORD.id().value(), record(TIME.plusNanos(1)).transition(),
                NotificationDeliveryState.PENDING, 0, TIME, TIME, null),
                AlertNotificationIntegrityException.Reason.CORRELATION_INVALID);
    }

    @Test
    void rejectsMalformedAttemptsStateAndRequiredTimes() {
        var invalid = List.of(
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), null, 0, TIME, TIME, null),
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), NotificationDeliveryState.PENDING, -1, TIME, TIME, null),
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), NotificationDeliveryState.PENDING, 0, null, TIME, null),
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), NotificationDeliveryState.PENDING, 0, TIME, null, null),
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), NotificationDeliveryState.DELIVERED, 1, TIME, TIME, null),
                new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), NotificationDeliveryState.PENDING, 1, TIME, TIME, TIME));
        invalid.forEach(delivery -> assertFailure(null, delivery, AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID));
    }

    @ParameterizedTest
    @EnumSource(value = NotificationDeliveryState.class, names = {"LEASED", "DELIVERED", "FAILED"})
    void rejectsClaimedOrTerminalDeliveryWithoutConsumedClaim(NotificationDeliveryState state) {
        var otherwiseValid = delivery(state);
        var zeroAttempts = new AlertNotificationEvidence.Delivery(otherwiseValid.id(), otherwiseValid.transition(),
                state, 0, otherwiseValid.createdAt(), otherwiseValid.nextAttemptAt(), otherwiseValid.completedAt());

        assertFailure(null, zeroAttempts, AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID);
    }

    private static AlertNotificationStatus project(NotificationDisposition disposition, AlertNotificationEvidence.Delivery delivery) {
        return new AlertNotificationProjectionService(ids -> List.of(
                new AlertNotificationEvidence(RECORD.id(), disposition, delivery)))
                .project(List.of(RECORD)).getFirst().notification();
    }

    private static void assertFailure(NotificationDisposition disposition, AlertNotificationEvidence.Delivery delivery,
            AlertNotificationIntegrityException.Reason reason) {
        assertThatThrownBy(() -> project(disposition, delivery))
                .isInstanceOfSatisfying(AlertNotificationIntegrityException.class, failure -> {
                    assertThat(failure.kind()).isEqualTo(AlertHistoryPersistenceException.Kind.INVARIANT);
                    assertThat(failure.reason()).isEqualTo(reason);
                });
    }

    private static AlertNotificationEvidence.Delivery delivery(NotificationDeliveryState state) {
        boolean terminal = state == NotificationDeliveryState.DELIVERED || state == NotificationDeliveryState.FAILED;
        return new AlertNotificationEvidence.Delivery(RECORD.id().value(), RECORD.transition(), state,
                2, TIME, TIME, terminal ? TIME.plusSeconds(3) : null);
    }

    private static AlertTransitionRecord record(Instant time) {
        var evaluation = new AlertEvaluation("checkout-burn", "Checkout burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                AlertEvaluationStatus.CONDITION_MET, null,
                new BurnRateEvidence("checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                        EvaluationWindow.PT5M, new TimeRange(time.minusSeconds(300), time), time, new BigDecimal("3"), null));
        return AlertTransitionRecord.forEpisode(AlertEpisode.opened("checkout-burn", time), new AlertTransition(
                "checkout-burn", AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, time, evaluation));
    }
}
