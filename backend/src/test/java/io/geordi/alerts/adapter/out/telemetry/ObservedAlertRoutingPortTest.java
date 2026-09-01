package io.geordi.alerts.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.port.out.AlertRoutingPort;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.RoutingDecision;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import java.math.BigDecimal;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class ObservedAlertRoutingPortTest {

    @Test
    void recordsEveryTerminalOutcomeWithOnlyTheAllowlistedTransitionDimension() {
        Counters counters = counters();
        AlertRoutingPort delegate = transition -> switch (transition.type()) {
            case ALERT_STARTED -> RoutingDecision.matched(new NotificationDestination("receiver-a", "fingerprint"));
            case ALERT_RESOLVED -> RoutingDecision.suppressed();
        };
        ObservedAlertRoutingPort observed = new ObservedAlertRoutingPort(delegate, counters.meter());

        observed.route(started());
        observed.route(resolved());
        new ObservedAlertRoutingPort(transition -> RoutingDecision.unrouted(), counters.meter()).route(started());

        assertCounterAttributes(counters.evaluations(), 3, "alert_started", "alert_resolved", "alert_started");
        assertCounterAttributes(counters.matched(), 1, "alert_started");
        assertCounterAttributes(counters.suppressed(), 1, "alert_resolved");
        assertCounterAttributes(counters.unrouted(), 1, "alert_started");
        verify(counters.failures(), org.mockito.Mockito.never()).add(eq(1L), org.mockito.ArgumentMatchers.any());
    }

    @Test
    void recordsRoutingFailureSeparatelyFromTerminalOutcomes() {
        Counters counters = counters();
        ObservedAlertRoutingPort observed = new ObservedAlertRoutingPort(
                transition -> { throw new IllegalStateException("routing unavailable"); }, counters.meter());

        assertThatThrownBy(() -> observed.route(resolved()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("routing unavailable");

        assertCounterAttributes(counters.evaluations(), 1, "alert_resolved");
        assertCounterAttributes(counters.failures(), 1, "alert_resolved");
        verify(counters.matched(), org.mockito.Mockito.never()).add(eq(1L), org.mockito.ArgumentMatchers.any());
        verify(counters.suppressed(), org.mockito.Mockito.never()).add(eq(1L), org.mockito.ArgumentMatchers.any());
        verify(counters.unrouted(), org.mockito.Mockito.never()).add(eq(1L), org.mockito.ArgumentMatchers.any());
    }

    private static void assertCounterAttributes(LongCounter counter, int expectedCount, String... transitions) {
        ArgumentCaptor<Attributes> attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(counter, org.mockito.Mockito.times(expectedCount)).add(eq(1L), attributes.capture());
        for (int index = 0; index < transitions.length; index++) {
            Attributes value = attributes.getAllValues().get(index);
            assertThat(value.asMap()).containsOnlyKeys(AttributeKey.stringKey("geordi.alert.routing.transition.type"));
            assertThat(value.get(AttributeKey.stringKey("geordi.alert.routing.transition.type")))
                    .isEqualTo(transitions[index]);
        }
    }

    private static Counters counters() {
        Meter meter = mock(Meter.class);
        LongCounter evaluations = counter(meter, "geordi.alert.routing.evaluations");
        LongCounter matched = counter(meter, "geordi.alert.routing.matched");
        LongCounter suppressed = counter(meter, "geordi.alert.routing.suppressed");
        LongCounter unrouted = counter(meter, "geordi.alert.routing.unrouted");
        LongCounter failures = counter(meter, "geordi.alert.routing.failures");
        return new Counters(meter, evaluations, matched, suppressed, unrouted, failures);
    }

    private static LongCounter counter(Meter meter, String name) {
        LongCounterBuilder builder = mock(LongCounterBuilder.class);
        LongCounter counter = mock(LongCounter.class);
        when(meter.counterBuilder(name)).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return counter;
    }

    private static AlertTransition started() {
        return transition(AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE,
                AlertLifecycleState.FIRING, AlertEvaluationStatus.CONDITION_MET);
    }

    private static AlertTransition resolved() {
        return transition(AlertTransitionType.ALERT_RESOLVED, AlertLifecycleState.FIRING,
                AlertLifecycleState.INACTIVE, AlertEvaluationStatus.CONDITION_NOT_MET);
    }

    private static AlertTransition transition(
            AlertTransitionType type, AlertLifecycleState previous, AlertLifecycleState current,
            AlertEvaluationStatus status) {
        Instant now = Instant.parse("2026-09-01T12:00:00Z");
        AlertEvaluation evaluation = new AlertEvaluation("policy-id", "Policy", "slo-id",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE), status, null,
                new BurnRateEvidence("slo-id", new ServiceIdentity("service", "namespace", "environment"),
                        EvaluationWindow.PT5M, new TimeRange(now.minusSeconds(300), now), now, BigDecimal.ONE, null));
        return new AlertTransition("policy-id", type, previous, current, now, evaluation);
    }

    private record Counters(
            Meter meter,
            LongCounter evaluations,
            LongCounter matched,
            LongCounter suppressed,
            LongCounter unrouted,
            LongCounter failures) {
    }
}
