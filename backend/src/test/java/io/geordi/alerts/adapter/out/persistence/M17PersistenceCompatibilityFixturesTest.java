package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertHistoryMutation;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionId;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.io.IOException;
import java.io.InputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Objects;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/**
 * Immutable M17 persistence truth captured at {@code eb9d807e5928deebe70e81df85e3fadb015928a1}.
 */
class M17PersistenceCompatibilityFixturesTest {

    private static final String RESOURCE_ROOT =
            "/io/geordi/alerts/adapter/out/persistence/compatibility/";
    private static final Instant STARTED_AT = Instant.parse("2026-09-01T20:00:00.123456789Z");
    private static final Instant UNAVAILABLE_AT = STARTED_AT.plusSeconds(300);
    private static final Instant RESOLVED_AT = STARTED_AT.plusSeconds(600);
    private static final AlertPersistenceJsonCodec CODEC =
            new AlertPersistenceJsonCodec(JsonMapper.builder().findAndAddModules().build());

    @Test
    void frozenLifecycleFixturesReproduceAuthoritativeM17SerializationAndEquality() throws IOException {
        AlertLifecycle firing = firing();
        AlertLifecycle firingUnavailable = firingUnavailable(firing);

        assertLifecycleFixture("lifecycle-inactive-unbound-v1.json", unboundInactive());
        assertLifecycleFixture("lifecycle-inactive-bound-v1.json", resolved(firingUnavailable));
        assertLifecycleFixture("lifecycle-firing-available-v1.json", firing);
        assertLifecycleFixture("lifecycle-firing-unavailable-latest-v1.json", firingUnavailable);
    }

    @Test
    void frozenTransitionHistoryAndPendingOutboxFixturesRetainExactM17Payloads() throws IOException {
        AlertLifecycle firing = firing();
        AlertTransition started = firing.latestTransition();
        AlertTransition resolved = resolved(firingUnavailable(firing)).latestTransition();

        assertTransitionFixture("transition-started-v1.json", started);
        assertTransitionFixture("transition-resolved-v1.json", resolved);
        assertTransitionFixture("history-transition-started-v1.json", started);
        assertTransitionFixture("history-transition-resolved-v1.json", resolved);
        assertTransitionFixture("outbox-pending-transition-v1.json", started);

        assertThat(readFixture("history-transition-started-v1.json"))
                .isEqualTo(readFixture("transition-started-v1.json"))
                .isEqualTo(readFixture("outbox-pending-transition-v1.json"));
        assertThat(readFixture("history-transition-resolved-v1.json"))
                .isEqualTo(readFixture("transition-resolved-v1.json"));
    }

    @Test
    void transitionEpisodeAndDeliveryIdentityVectorsRemainFixed() {
        AlertLifecycle firing = firing();
        AlertTransition started = firing.latestTransition();
        AlertTransition resolved = resolved(firingUnavailable(firing)).latestTransition();
        AlertEpisode episode = AlertEpisode.opened("checkout-burn", STARTED_AT);

        assertThat(AlertTransitionId.from(started).value())
                .isEqualTo("b60804323cfde1dffbe027b8ade731ab41b21d90d109056024665546c251285c");
        assertThat(AlertTransitionId.from(resolved).value())
                .isEqualTo("43dbf2318e8d32fb74d3b233bb4babb346c785bedf92def2ed71fcd5da2853dc");
        assertThat(episode.id().value())
                .isEqualTo("d66bbfb267883399447c33a42a5140b4b7700ea1ef35564c367ad758e8b8a716");
        assertThat(AlertEpisode.legacyResolved("checkout-burn", RESOLVED_AT).id().value())
                .isEqualTo("3e035a5971c97a3d73f792c179d17cc667f7b7ba1c1a72141a82756b83248c9a");

        AlertHistoryMutation.Opened opening = (AlertHistoryMutation.Opened) AlertHistoryMutation.from(started);
        AlertHistoryMutation.Resolved resolution = (AlertHistoryMutation.Resolved) AlertHistoryMutation.from(resolved);
        assertThat(opening.record().episodeId()).isEqualTo(episode.id());
        assertThat(resolution.recordFor(episode.resolve(RESOLVED_AT)).episodeId()).isEqualTo(episode.id());

        NotificationDestination destination = new NotificationDestination("operations-webhook", "f1a5b7c9");
        assertThat(NotificationDelivery.pending(started, destination, STARTED_AT).id())
                .isEqualTo("b60804323cfde1dffbe027b8ade731ab41b21d90d109056024665546c251285c");
        assertThat(NotificationDelivery.pending(resolved, destination, RESOLVED_AT).id())
                .isEqualTo("43dbf2318e8d32fb74d3b233bb4babb346c785bedf92def2ed71fcd5da2853dc");
    }

    private static void assertLifecycleFixture(String name, AlertLifecycle expected) throws IOException {
        String frozenJson = readFixture(name);
        assertThat(frozenJson).doesNotContain("persistenceFormatVersion");
        assertThat(CODEC.readLifecycle(frozenJson)).isEqualTo(expected);
        assertThat(CODEC.writeLifecycle(expected)).isEqualTo(frozenJson);
    }

    private static void assertTransitionFixture(String name, AlertTransition expected) throws IOException {
        String frozenJson = readFixture(name);
        assertThat(frozenJson).doesNotContain("persistenceFormatVersion");
        assertThat(CODEC.readTransition(frozenJson)).isEqualTo(expected);
        assertThat(CODEC.writeTransition(expected)).isEqualTo(frozenJson);
    }

    private static String readFixture(String name) throws IOException {
        try (InputStream stream = Objects.requireNonNull(
                M17PersistenceCompatibilityFixturesTest.class.getResourceAsStream(RESOURCE_ROOT + name),
                "missing M17 persistence fixture " + name)) {
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8).stripTrailing();
        }
    }

    private static AlertLifecycle unboundInactive() {
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(),
                AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.DISABLED, null);
        return AlertLifecycleTransitions.apply(
                Optional.empty(), evaluation, STARTED_AT.minusSeconds(300)).current();
    }

    private static AlertLifecycle firing() {
        return AlertLifecycleTransitions.apply(
                Optional.empty(), availableEvaluation(AlertEvaluationStatus.CONDITION_MET, STARTED_AT), null).current();
    }

    private static AlertLifecycle firingUnavailable(AlertLifecycle firing) {
        AlertEvaluation unavailable = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(),
                AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.METRICS_UNAVAILABLE,
                evidence(UNAVAILABLE_AT, null, AlertUnavailableReason.METRICS_UNAVAILABLE));
        return AlertLifecycleTransitions.apply(Optional.of(firing), unavailable, null).current();
    }

    private static AlertLifecycle resolved(AlertLifecycle firing) {
        return AlertLifecycleTransitions.apply(
                Optional.of(firing), availableEvaluation(AlertEvaluationStatus.CONDITION_NOT_MET, RESOLVED_AT), null)
                .current();
    }

    private static AlertEvaluation availableEvaluation(AlertEvaluationStatus status, Instant evaluatedAt) {
        BigDecimal burnRate = status == AlertEvaluationStatus.CONDITION_MET
                ? new BigDecimal("3.00")
                : new BigDecimal("0.50");
        return new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability", condition(), status, null,
                evidence(evaluatedAt, burnRate, null));
    }

    private static BurnRateEvidence evidence(
            Instant evaluatedAt, BigDecimal burnRate, AlertUnavailableReason reason) {
        return new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(evaluatedAt.minusSeconds(300), evaluatedAt), evaluatedAt,
                burnRate, reason);
    }

    private static AlertCondition condition() {
        return new io.geordi.alerts.domain.BurnRateAboveCondition(new BigDecimal("2.00"));
    }
}
