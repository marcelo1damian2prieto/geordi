package io.geordi.alerts.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.alerts.application.AlertHistoryQueryService;
import io.geordi.alerts.application.AlertNotificationEvidence;
import io.geordi.alerts.application.port.out.AlertNotificationEvidenceQuery;
import io.geordi.alerts.domain.AlertTransitionId;
import io.geordi.alerts.domain.NotificationDisposition;
import io.geordi.alerts.domain.NotificationDeliveryState;
import io.geordi.alerts.application.AcknowledgeAlertEpisodeUseCase;
import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertHistoryRepository;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class AlertHistoryControllerTest {

    private static final Instant STARTED_AT = Instant.parse("2026-08-27T17:00:00Z");
    private static final AlertEpisode EPISODE = AlertEpisode.opened("checkout-burn", STARTED_AT)
            .resolve(STARTED_AT.plusSeconds(300));
    private static final AlertTransitionRecord TRANSITION = AlertTransitionRecord.forEpisode(
            EPISODE, transition());

    @Test
    void listsBoundedEpisodesWithoutEvaluatingLifecycle() throws Exception {
        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION))).perform(get("/api/alert-episodes")
                        .param("policyId", "checkout-burn"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertEpisodes[0].id").value(EPISODE.id().value()))
                .andExpect(jsonPath("$.alertEpisodes[0].openedAt").value("2026-08-27T17:00:00Z"))
                .andExpect(jsonPath("$.alertEpisodes[0].durationSeconds").value(300));
    }

    @Test
    void rejectsAnUnboundedEpisodeQueryWithTheProblemContract() throws Exception {
        mvc(new Repository(List.of(), List.of())).perform(get("/api/alert-episodes"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.title").value("Invalid alert history request"));
    }

    @Test
    void returnsEpisodeDetailWithItsImmutableTransitions() throws Exception {
        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION)))
                .perform(get("/api/alert-episodes/{episodeId}", EPISODE.id().value()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.episode.policyId").value("checkout-burn"))
                .andExpect(jsonPath("$.transitions[0].id").value(TRANSITION.id().value()))
                .andExpect(jsonPath("$.transitions[0].type").value("ALERT_STARTED"))
                .andExpect(jsonPath("$.transitions[0].notification.disposition").value("NOT_RECORDED"))
                .andExpect(jsonPath("$.transitions[0].notification.delivery").isEmpty());
    }

    @Test
    void exposesOnlySafeDeliveryStatusFieldsInDetail() throws Exception {
        var delivery = new AlertNotificationEvidence.Delivery(TRANSITION.id().value(), TRANSITION.transition(),
                NotificationDeliveryState.DELIVERED, 2, STARTED_AT, STARTED_AT, STARTED_AT.plusSeconds(2));
        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION), List.of(
                new AlertNotificationEvidence(TRANSITION.id(), NotificationDisposition.MATCHED, delivery))))
                .perform(get("/api/alert-episodes/{episodeId}", EPISODE.id().value()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.transitions[0].notification.disposition").value("MATCHED"))
                .andExpect(jsonPath("$.transitions[0].notification.delivery.state").value("DELIVERED"))
                .andExpect(jsonPath("$.transitions[0].notification.delivery.attempts").value(2))
                .andExpect(jsonPath("$.transitions[0].notification.delivery.nextAttemptAt").isEmpty())
                .andExpect(jsonPath("$.transitions[0].notification.delivery.completedAt").value("2026-08-27T17:00:02Z"))
                .andExpect(jsonPath("$.transitions[0].notification.delivery.*", org.hamcrest.Matchers.hasSize(5)))
                .andExpect(jsonPath("$.transitions[0].notification.delivery.id").doesNotExist())
                .andExpect(jsonPath("$.transitions[0].notification.delivery.destination").doesNotExist())
                .andExpect(jsonPath("$.transitions[0].notification.delivery.transition").doesNotExist())
                .andExpect(jsonPath("$.transitions[0].notification.delivery.claimToken").doesNotExist());
    }

    @Test
    void inconsistentDurableNotificationEvidenceFailsTheEntireDetailWithSanitized503() throws Exception {
        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION), List.of(
                new AlertNotificationEvidence(TRANSITION.id(), NotificationDisposition.MATCHED, null))))
                .perform(get("/api/alert-episodes/{episodeId}", EPISODE.id().value()))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.episode").doesNotExist())
                .andExpect(jsonPath("$.transitions").doesNotExist())
                .andExpect(jsonPath("$.detail").value("Alert history could not be read"));
    }

    @ParameterizedTest
    @EnumSource(value = NotificationDeliveryState.class, names = {"LEASED", "DELIVERED", "FAILED"})
    void zeroAttemptClaimedOrTerminalEvidenceFailsDetailWithSanitized503(NotificationDeliveryState state) throws Exception {
        boolean terminal = state == NotificationDeliveryState.DELIVERED || state == NotificationDeliveryState.FAILED;
        var delivery = new AlertNotificationEvidence.Delivery(TRANSITION.id().value(), TRANSITION.transition(),
                state, 0, STARTED_AT, STARTED_AT, terminal ? STARTED_AT.plusSeconds(2) : null);

        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION), List.of(
                new AlertNotificationEvidence(TRANSITION.id(), NotificationDisposition.MATCHED, delivery))))
                .perform(get("/api/alert-episodes/{episodeId}", EPISODE.id().value()))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.episode").doesNotExist())
                .andExpect(jsonPath("$.transitions").doesNotExist())
                .andExpect(jsonPath("$.detail").value("Alert history could not be read"));
    }

    @Test
    void mapsInvalidEpisodeIdToBadRequest() throws Exception {
        mvc(new Repository(List.of(), List.of())).perform(get("/api/alert-episodes/not-an-id"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.title").value("Invalid alert history request"));
    }

    @Test
    void listsTransitionsWithinAnEpisodeWithoutReevaluatingAnything() throws Exception {
        mvc(new Repository(List.of(EPISODE), List.of(TRANSITION))).perform(get("/api/alert-transitions")
                        .param("episodeId", EPISODE.id().value()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertTransitions[0].episodeId").value(EPISODE.id().value()))
                .andExpect(jsonPath("$.alertTransitions[0].occurredAt").value("2026-08-27T17:00:00Z"))
                .andExpect(jsonPath("$.alertTransitions[0].notification").doesNotExist());
    }

    @Test
    void acceptsTheDocumentedTransitionLimitBoundaryForAPolicyScopedQuery() throws Exception {
        mvc(new Repository(List.of(), List.of(TRANSITION))).perform(get("/api/alert-transitions")
                        .param("policyId", "checkout-burn")
                        .param("limit", "100"))
                .andExpect(status().isOk());
    }

    @Test
    void mapsMalformedEpisodeTimeToBadRequest() throws Exception {
        mvc(new Repository(List.of(), List.of())).perform(get("/api/alert-episodes")
                        .param("policyId", "checkout-burn")
                        .param("from", "not-an-instant")
                        .param("to", "2026-08-27T18:00:00Z"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.title").value("Invalid alert history request"));
    }

    @Test
    void mapsMalformedTransitionTimeToBadRequest() throws Exception {
        mvc(new Repository(List.of(), List.of())).perform(get("/api/alert-transitions")
                        .param("policyId", "checkout-burn")
                        .param("from", "2026-08-27T17:00:00Z")
                        .param("to", "not-an-instant"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.title").value("Invalid alert history request"));
    }

    private static MockMvc mvc(Repository repository) {
        AcknowledgeAlertEpisodeUseCase acknowledgements = (episodeId, actor, reason) -> {
            throw new AssertionError("history-query tests must not invoke acknowledgement");
        };
        return MockMvcBuilders.standaloneSetup(
                        new AlertHistoryController(new AlertHistoryQueryService(repository,
                                org.mockito.Mockito.mock(io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository.class),
                                new io.geordi.alerts.application.AlertNotificationProjectionService(repository)), acknowledgements))
                .setControllerAdvice(new AlertHistoryExceptionHandler())
                .build();
    }

    private static AlertTransition transition() {
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                AlertEvaluationStatus.CONDITION_MET, null,
                new BurnRateEvidence(
                        "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                        EvaluationWindow.PT5M, new TimeRange(STARTED_AT.minusSeconds(300), STARTED_AT), STARTED_AT,
                        new BigDecimal("3"), null));
        return new AlertTransition(
                "checkout-burn", AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, STARTED_AT, evaluation);
    }

    private record Repository(List<AlertEpisode> episodes, List<AlertTransitionRecord> transitions,
            List<AlertNotificationEvidence> evidence) implements AlertHistoryRepository, AlertNotificationEvidenceQuery {

        Repository(List<AlertEpisode> episodes, List<AlertTransitionRecord> transitions) {
            this(episodes, transitions, List.of());
        }

        @Override
        public List<AlertNotificationEvidence> findNotificationEvidence(List<AlertTransitionId> ids) {
            return evidence;
        }

        @Override
        public Optional<AlertEpisode> findEpisodeById(AlertEpisodeId episodeId) {
            return episodes.stream().filter(episode -> episode.id().equals(episodeId)).findFirst();
        }

        @Override
        public List<AlertEpisode> findEpisodes(AlertEpisodeHistoryQuery query) {
            return episodes;
        }

        @Override
        public List<AlertTransitionRecord> findTransitions(AlertTransitionHistoryQuery query) {
            return transitions;
        }
    }
}
