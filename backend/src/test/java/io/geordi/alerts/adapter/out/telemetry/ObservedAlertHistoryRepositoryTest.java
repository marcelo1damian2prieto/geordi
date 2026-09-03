package io.geordi.alerts.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertHistoryRepository;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertHistoryMutation;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class ObservedAlertHistoryRepositoryTest {

    @Test
    void recordsEpisodeAndPersistenceSuccessOnlyForCommittedHistoryMutation() {
        RepositoryFixture fixture = fixture();
        AlertHistoryMutation mutation = AlertHistoryMutation.from(started());
        AlertLifecycle lifecycle = mock(AlertLifecycle.class);
        when(fixture.lifecycle().commit(eq(lifecycle), eq(Optional.empty()), eq(Optional.empty()), any()))
                .thenReturn(true);

        boolean committed = fixture.observed().commit(
                lifecycle, Optional.empty(), Optional.empty(), Optional.of(mutation));

        assertThat(committed).isTrue();
        assertSingleAttribute(fixture.episodes(), "geordi.alert.history.transition.type", "alert_started");
        assertSingleAttribute(fixture.persistence(), "geordi.alert.history.outcome", "success");
    }

    @Test
    void doesNotGuessThatCombinedCommitFailureCameFromHistoryPersistence() {
        RepositoryFixture fixture = fixture();
        AlertLifecycle lifecycle = mock(AlertLifecycle.class);
        when(fixture.lifecycle().commit(eq(lifecycle), eq(Optional.empty()), eq(Optional.empty()), any()))
                .thenThrow(new IllegalStateException("history transaction failed"));

        assertThatThrownBy(() -> fixture.observed().commit(
                        lifecycle,
                        Optional.empty(),
                        Optional.empty(),
                        Optional.of(AlertHistoryMutation.from(started()))))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("history transaction failed");

        verify(fixture.persistence(), never()).add(eq(1L), any(Attributes.class));
        verify(fixture.episodes(), never()).add(eq(1L), any(Attributes.class));
    }

    @Test
    void doesNotRecordOrdinaryLifecyclePersistenceAsHistoryPersistence() {
        RepositoryFixture fixture = fixture();
        AlertLifecycle lifecycle = mock(AlertLifecycle.class);
        when(fixture.lifecycle().commit(lifecycle, Optional.empty(), Optional.empty(), Optional.empty()))
                .thenThrow(new IllegalStateException("lifecycle persistence failed"));

        assertThatThrownBy(() -> fixture.observed().commit(
                        lifecycle, Optional.empty(), Optional.empty(), Optional.empty()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("lifecycle persistence failed");

        verify(fixture.persistence(), never()).add(eq(1L), any(Attributes.class));
        verify(fixture.episodes(), never()).add(eq(1L), any(Attributes.class));
    }

    @Test
    void recordsBoundedQuerySuccessAndFailureOutcomes() {
        RepositoryFixture fixture = fixture();
        AlertEpisodeId episodeId = AlertEpisodeId.opened("policy-id", NOW);
        AlertEpisodeHistoryQuery episodes = new AlertEpisodeHistoryQuery("policy-id", null, null, null, 10);
        AlertTransitionHistoryQuery transitions =
                new AlertTransitionHistoryQuery("policy-id", null, null, null, 10);
        when(fixture.history().findEpisodeById(episodeId)).thenReturn(Optional.empty());
        when(fixture.history().findEpisodes(episodes)).thenReturn(List.of());
        when(fixture.history().findTransitions(transitions))
                .thenThrow(new IllegalStateException("query unavailable"));

        assertThat(fixture.observed().findEpisodeById(episodeId)).isEmpty();
        assertThat(fixture.observed().findEpisodes(episodes)).isEmpty();
        assertThatThrownBy(() -> fixture.observed().findTransitions(transitions))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("query unavailable");

        ArgumentCaptor<Attributes> attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(fixture.queries(), times(3)).add(eq(1L), attributes.capture());
        assertQueryAttributes(attributes.getAllValues().get(0), "episode_by_id", "success");
        assertQueryAttributes(attributes.getAllValues().get(1), "episodes", "success");
        assertQueryAttributes(attributes.getAllValues().get(2), "transitions", "failure");
    }

    private static void assertSingleAttribute(LongCounter counter, String key, String value) {
        ArgumentCaptor<Attributes> attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(counter).add(eq(1L), attributes.capture());
        assertThat(attributes.getValue().asMap()).containsOnlyKeys(AttributeKey.stringKey(key));
        assertThat(attributes.getValue().get(AttributeKey.stringKey(key))).isEqualTo(value);
    }

    private static void assertQueryAttributes(Attributes attributes, String operation, String outcome) {
        AttributeKey<String> operationKey = AttributeKey.stringKey("geordi.alert.history.query.operation");
        AttributeKey<String> outcomeKey = AttributeKey.stringKey("geordi.alert.history.outcome");
        assertThat(attributes.asMap()).containsOnlyKeys(operationKey, outcomeKey);
        assertThat(attributes.get(operationKey)).isEqualTo(operation);
        assertThat(attributes.get(outcomeKey)).isEqualTo(outcome);
    }

    private static RepositoryFixture fixture() {
        AlertLifecycleRepository lifecycle = mock(AlertLifecycleRepository.class);
        AlertHistoryRepository history = mock(AlertHistoryRepository.class);
        Meter meter = mock(Meter.class);
        LongCounter episodes = counter(meter, "geordi.alert.history.episodes");
        LongCounter persistence = counter(meter, "geordi.alert.history.persistence");
        LongCounter queries = counter(meter, "geordi.alert.history.queries");
        return new RepositoryFixture(
                lifecycle,
                history,
                new ObservedAlertHistoryRepository(lifecycle, history, meter),
                episodes,
                persistence,
                queries);
    }

    private static LongCounter counter(Meter meter, String name) {
        LongCounterBuilder builder = mock(LongCounterBuilder.class);
        LongCounter counter = mock(LongCounter.class);
        when(meter.counterBuilder(name)).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return counter;
    }

    private static AlertTransition started() {
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE);
        BurnRateEvidence evidence = new BurnRateEvidence(
                "slo-id",
                new ServiceIdentity("service", "namespace", "environment"),
                EvaluationWindow.PT5M,
                new TimeRange(NOW.minusSeconds(300), NOW),
                NOW,
                BigDecimal.ONE,
                null);
        AlertEvaluation evaluation = new AlertEvaluation(
                "policy-id", "Policy", "slo-id", condition, AlertEvaluationStatus.CONDITION_MET, null, evidence);
        return new AlertTransition(
                "policy-id",
                AlertTransitionType.ALERT_STARTED,
                AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING,
                NOW,
                evaluation);
    }

    private static final Instant NOW = Instant.parse("2026-09-01T12:00:00Z");

    private record RepositoryFixture(
            AlertLifecycleRepository lifecycle,
            AlertHistoryRepository history,
            ObservedAlertHistoryRepository observed,
            LongCounter episodes,
            LongCounter persistence,
            LongCounter queries) {
    }
}
