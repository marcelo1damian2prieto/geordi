package io.geordi.alerts.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.AlertHistoryPersistenceException;
import io.geordi.alerts.application.AlertNotificationIntegrityException;
import io.geordi.alerts.application.AlertNotificationProjectionQuery;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import java.util.List;
import java.util.Locale;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.ArgumentCaptor;

class ObservedAlertNotificationProjectionQueryTest {

    @Test
    void recordsSuccessOnceWithoutTransitionOrDeliveryAttributes() {
        Fixture fixture = fixture();
        List<AlertTransitionRecord> transitions = List.of(mock(AlertTransitionRecord.class));
        when(fixture.delegate().project(transitions)).thenReturn(List.of());

        assertThat(fixture.observed().project(transitions)).isEmpty();

        verify(fixture.delegate()).project(transitions);
        assertSingleAttribute(fixture.queries(), "geordi.alert.notification.outcome", "success");
        verify(fixture.integrity(), never()).add(eq(1L), any(Attributes.class));
    }

    @Test
    void recordsPersistenceFailureWithoutExceptionText() {
        Fixture fixture = fixture();
        var exception = new AlertHistoryPersistenceException(
                AlertHistoryPersistenceException.Kind.PERSISTENCE, "jdbc sensitive payload", null);
        when(fixture.delegate().project(List.of())).thenThrow(exception);

        assertThatThrownBy(() -> fixture.observed().project(List.of())).isSameAs(exception);

        assertSingleAttribute(fixture.queries(), "geordi.alert.notification.outcome", "persistence_failure");
        verify(fixture.integrity(), never()).add(eq(1L), any(Attributes.class));
    }

    @ParameterizedTest
    @EnumSource(AlertNotificationIntegrityException.Reason.class)
    void recordsOnlyBoundedIntegrityReason(AlertNotificationIntegrityException.Reason reason) {
        Fixture fixture = fixture();
        AlertNotificationIntegrityException exception = new AlertNotificationIntegrityException(reason);
        when(fixture.delegate().project(List.of())).thenThrow(exception);

        assertThatThrownBy(() -> fixture.observed().project(List.of())).isSameAs(exception);

        assertSingleAttribute(fixture.queries(), "geordi.alert.notification.outcome", "invariant_failure");
        assertSingleAttribute(fixture.integrity(), "geordi.alert.notification.integrity.reason",
                reason.name().toLowerCase(Locale.ROOT));
    }

    private static void assertSingleAttribute(LongCounter counter, String key, String expected) {
        ArgumentCaptor<Attributes> attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(counter).add(eq(1L), attributes.capture());
        AttributeKey<String> attribute = AttributeKey.stringKey(key);
        assertThat(attributes.getValue().asMap()).containsOnlyKeys(attribute);
        assertThat(attributes.getValue().get(attribute)).isEqualTo(expected);
    }

    private static Fixture fixture() {
        AlertNotificationProjectionQuery delegate = mock(AlertNotificationProjectionQuery.class);
        Meter meter = mock(Meter.class);
        LongCounter queries = counter(meter, "geordi.alert.notification.projections");
        LongCounter integrity = counter(meter, "geordi.alert.notification.integrity.failures");
        return new Fixture(delegate, new ObservedAlertNotificationProjectionQuery(delegate, meter), queries, integrity);
    }

    private static LongCounter counter(Meter meter, String name) {
        LongCounterBuilder builder = mock(LongCounterBuilder.class);
        LongCounter counter = mock(LongCounter.class);
        when(meter.counterBuilder(name)).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return counter;
    }

    private record Fixture(AlertNotificationProjectionQuery delegate,
            ObservedAlertNotificationProjectionQuery observed, LongCounter queries, LongCounter integrity) {
    }
}
