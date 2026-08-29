package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.alerts.application.port.out.NotificationDeliveryWorkRepository;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import org.junit.jupiter.api.Test;

class NotificationDeliveryWorkServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-28T19:00:00Z");

    @Test
    void claimsDueWorkUsingTheInjectedClockAndLeaseDuration() {
        RecordingRepository repository = new RecordingRepository();
        NotificationDeliveryWorkService service = service(repository);

        assertThat(service.claimDue(3, Duration.ofSeconds(10), 4)).isEmpty();

        assertThat(repository.claimedAt).isEqualTo(NOW);
        assertThat(repository.leaseExpiresAt).isEqualTo(NOW.plusSeconds(10));
        assertThat(repository.limit).isEqualTo(3);
        assertThat(repository.maximumAttempts).isEqualTo(4);
    }

    @Test
    void completesOrRetriesOnlyTheClaimedDeliveryAndBoundsAttempts() {
        RecordingRepository repository = new RecordingRepository();
        NotificationDeliveryWorkService service = service(repository);
        NotificationDelivery claimed = delivery(1).leased("claim", NOW.plusSeconds(30));

        assertThat(service.markDelivered(claimed)).isTrue();
        assertThat(repository.deliveredId).isEqualTo(claimed.id());
        assertThat(repository.deliveredToken).isEqualTo("claim");
        assertThat(repository.deliveredAt).isEqualTo(NOW);

        assertThat(service.retryOrFail(claimed, NOW.plusSeconds(5), 3)).isTrue();
        assertThat(repository.retryAt).isEqualTo(NOW.plusSeconds(5));
        assertThat(repository.failedId).isNull();

        NotificationDelivery finalAttempt = delivery(2).leased("final-claim", NOW.plusSeconds(30));
        assertThat(service.retryOrFail(finalAttempt, NOW.plusSeconds(5), 3)).isTrue();
        assertThat(repository.failedId).isEqualTo(finalAttempt.id());
        assertThat(repository.failedToken).isEqualTo("final-claim");
        assertThat(repository.failedAt).isEqualTo(NOW);
    }

    private static NotificationDeliveryWorkService service(RecordingRepository repository) {
        return new NotificationDeliveryWorkService(repository, Clock.fixed(NOW, ZoneOffset.UTC));
    }

    private static NotificationDelivery delivery(int attempts) {
        AlertTransition transition = transition();
        return new NotificationDelivery(
                NotificationDelivery.stableId(transition), transition,
                new NotificationDestination("operations-webhook", "fingerprint"),
                io.geordi.alerts.domain.NotificationDeliveryState.PENDING, attempts,
                NOW, NOW, null, null, null);
    }

    private static AlertTransition transition() {
        BurnRateEvidence evidence = new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW, new BigDecimal("3"), null);
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
        return new AlertTransition(
                "checkout-burn", AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, NOW, evaluation);
    }

    private static final class RecordingRepository implements NotificationDeliveryWorkRepository {

        private Instant claimedAt;
        private Instant leaseExpiresAt;
        private int limit;
        private int maximumAttempts;
        private String deliveredId;
        private String deliveredToken;
        private Instant deliveredAt;
        private Instant retryAt;
        private String failedId;
        private String failedToken;
        private Instant failedAt;

        @Override
        public List<NotificationDelivery> claimDue(
                Instant now, Instant leaseExpiry, int value, int attemptsLimit) {
            claimedAt = now;
            leaseExpiresAt = leaseExpiry;
            limit = value;
            maximumAttempts = attemptsLimit;
            return List.of();
        }

        @Override
        public boolean markDelivered(String deliveryId, String claimToken, Instant completedAt) {
            deliveredId = deliveryId;
            deliveredToken = claimToken;
            deliveredAt = completedAt;
            return true;
        }

        @Override
        public boolean reschedule(String deliveryId, String claimToken, Instant nextAttemptAt) {
            retryAt = nextAttemptAt;
            return true;
        }

        @Override
        public boolean markFailed(String deliveryId, String claimToken, Instant completedAt) {
            failedId = deliveryId;
            failedToken = claimToken;
            failedAt = completedAt;
            return true;
        }
    }
}
