package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertHistoryMutationTest {

    private static final Instant OCCURRED_AT = Instant.parse("2026-09-01T20:00:00Z");

    @Test
    void normalStartHasStableEpisodeAndTransitionIdentities() {
        AlertTransition transition = transition(AlertTransitionType.ALERT_STARTED);

        AlertHistoryMutation.Opened mutation = (AlertHistoryMutation.Opened) AlertHistoryMutation.from(transition);

        assertThat(mutation.episode()).isEqualTo(AlertEpisode.opened("checkout-burn", OCCURRED_AT));
        assertThat(mutation.record().id().value()).isEqualTo(NotificationDelivery.stableId(transition));
        assertThat(mutation.record().episodeId()).isEqualTo(mutation.episode().id());
    }

    @Test
    void legacyResolutionNeverFabricatesAnOpeningTime() {
        AlertTransition transition = transition(AlertTransitionType.ALERT_RESOLVED);

        AlertHistoryMutation.Resolved mutation = (AlertHistoryMutation.Resolved) AlertHistoryMutation.from(transition);

        assertThat(mutation.legacyEpisode())
                .satisfies(episode -> {
                    assertThat(episode.origin()).isEqualTo(AlertEpisodeOrigin.PRE_M14_UNKNOWN_START);
                    assertThat(episode.openedAt()).isNull();
                    assertThat(episode.closedAt()).isEqualTo(OCCURRED_AT);
                });
        assertThat(mutation.legacyEpisode().id())
                .isNotEqualTo(AlertEpisodeId.opened("checkout-burn", OCCURRED_AT));
    }

    @Test
    void episodeCannotCloseBeforeItsCanonicalOpening() {
        AlertEpisode episode = AlertEpisode.opened("checkout-burn", OCCURRED_AT);

        assertThatThrownBy(() -> episode.resolve(OCCURRED_AT.minusSeconds(1)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert episode cannot close before it opens");
    }

    private static AlertTransition transition(AlertTransitionType type) {
        AlertEvaluationStatus status = type == AlertTransitionType.ALERT_STARTED
                ? AlertEvaluationStatus.CONDITION_MET
                : AlertEvaluationStatus.CONDITION_NOT_MET;
        AlertLifecycleState previous = type == AlertTransitionType.ALERT_STARTED
                ? AlertLifecycleState.INACTIVE
                : AlertLifecycleState.FIRING;
        AlertLifecycleState current = type == AlertTransitionType.ALERT_STARTED
                ? AlertLifecycleState.FIRING
                : AlertLifecycleState.INACTIVE;
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2"));
        BurnRateEvidence evidence = new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(OCCURRED_AT.minusSeconds(300), OCCURRED_AT), OCCURRED_AT,
                new BigDecimal("3"), null);
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition, status, null, evidence);
        return new AlertTransition("checkout-burn", type, previous, current, OCCURRED_AT, evaluation);
    }
}
