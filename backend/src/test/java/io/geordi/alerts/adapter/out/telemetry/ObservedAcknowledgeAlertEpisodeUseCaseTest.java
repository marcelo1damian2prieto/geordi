package io.geordi.alerts.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.AcknowledgeAlertEpisodeUseCase;
import io.geordi.alerts.application.AlertEpisodeAcknowledgementConflictException;
import io.geordi.alerts.application.AlertEpisodeNotFoundException;
import io.geordi.alerts.domain.AlertEpisodeAcknowledgement;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class ObservedAcknowledgeAlertEpisodeUseCaseTest {

    private static final AlertEpisodeId ID = AlertEpisodeId.opened("policy", Instant.EPOCH);
    private static final AlertEpisodeAcknowledgement ACKNOWLEDGEMENT =
            new AlertEpisodeAcknowledgement(ID, "operator", null, Instant.EPOCH);

    @Test
    void recordsEachBoundedOutcomeOnceWithoutCommandDataAttributes() {
        AcknowledgeAlertEpisodeUseCase delegate = mock(AcknowledgeAlertEpisodeUseCase.class);
        LongCounter counter = counter();
        when(delegate.acknowledge(ID, "created", null)).thenReturn(result(AcknowledgeAlertEpisodeUseCase.AcknowledgementResult.Status.CREATED));
        when(delegate.acknowledge(ID, "replayed", null)).thenReturn(result(AcknowledgeAlertEpisodeUseCase.AcknowledgementResult.Status.REPLAYED));
        when(delegate.acknowledge(ID, "invalid", null)).thenThrow(new IllegalArgumentException());
        when(delegate.acknowledge(ID, "missing", null)).thenThrow(new AlertEpisodeNotFoundException());
        when(delegate.acknowledge(ID, "conflict", null)).thenThrow(new AlertEpisodeAcknowledgementConflictException());
        when(delegate.acknowledge(ID, "failure", null)).thenThrow(new IllegalStateException());
        var observed = new ObservedAcknowledgeAlertEpisodeUseCase(delegate, meter(counter));

        observed.acknowledge(ID, "created", null);
        observed.acknowledge(ID, "replayed", null);
        assertThatThrownBy(() -> observed.acknowledge(ID, "invalid", null)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> observed.acknowledge(ID, "missing", null)).isInstanceOf(AlertEpisodeNotFoundException.class);
        assertThatThrownBy(() -> observed.acknowledge(ID, "conflict", null)).isInstanceOf(AlertEpisodeAcknowledgementConflictException.class);
        assertThatThrownBy(() -> observed.acknowledge(ID, "failure", null)).isInstanceOf(IllegalStateException.class);

        ArgumentCaptor<Attributes> attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(counter, times(6)).add(eq(1L), attributes.capture());
        AttributeKey<String> outcome = AttributeKey.stringKey("geordi.alert.acknowledgement.outcome");
        assertThat(attributes.getAllValues())
                .allSatisfy(value -> assertThat(value.asMap()).containsOnlyKeys(outcome));
        assertThat(attributes.getAllValues().stream().map(value -> value.get(outcome)).toList())
                .containsExactly("created", "replayed", "invalid", "not_found", "conflict", "failure");
    }

    private static AcknowledgeAlertEpisodeUseCase.AcknowledgementResult result(
            AcknowledgeAlertEpisodeUseCase.AcknowledgementResult.Status status) {
        return new AcknowledgeAlertEpisodeUseCase.AcknowledgementResult(status, ACKNOWLEDGEMENT);
    }

    private static Meter meter(LongCounter counter) {
        Meter meter = mock(Meter.class);
        LongCounterBuilder builder = mock(LongCounterBuilder.class);
        when(meter.counterBuilder("geordi.alert.acknowledgements")).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return meter;
    }

    private static LongCounter counter() {
        return mock(LongCounter.class);
    }
}
