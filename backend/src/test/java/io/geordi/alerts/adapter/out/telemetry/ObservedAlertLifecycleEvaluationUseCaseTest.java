package io.geordi.alerts.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.DoubleHistogramBuilder;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import org.junit.jupiter.api.Test;

class ObservedAlertLifecycleEvaluationUseCaseTest {

    @Test
    void doesNotClassifyGeneralLifecycleFailuresAsHistoryPersistenceFailures() {
        Meter meter = mock(Meter.class);
        counter(meter, "geordi.alert.lifecycle.evaluations");
        counter(meter, "geordi.alert.lifecycle.results");
        counter(meter, "geordi.alert.lifecycle.transitions");
        LongCounter failures = counter(meter, "geordi.alert.lifecycle.failures");
        histogram(meter, "geordi.alert.lifecycle.duration");
        AlertLifecycleEvaluationUseCase delegate = policyId -> {
            throw new IllegalStateException("routing unavailable");
        };

        ObservedAlertLifecycleEvaluationUseCase observed =
                new ObservedAlertLifecycleEvaluationUseCase(delegate, meter);

        assertThatThrownBy(() -> observed.evaluate("policy-id"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("routing unavailable");

        verify(failures).add(1);
        verify(meter, never()).counterBuilder("geordi.alert.history.persistence");
        verify(meter, never()).counterBuilder("geordi.alert.history.episodes");
    }

    private static LongCounter counter(Meter meter, String name) {
        LongCounterBuilder builder = mock(LongCounterBuilder.class);
        LongCounter counter = mock(LongCounter.class);
        when(meter.counterBuilder(name)).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return counter;
    }

    private static DoubleHistogram histogram(Meter meter, String name) {
        DoubleHistogramBuilder builder = mock(DoubleHistogramBuilder.class);
        DoubleHistogram histogram = mock(DoubleHistogram.class);
        when(meter.histogramBuilder(name)).thenReturn(builder);
        when(builder.setUnit("s")).thenReturn(builder);
        when(builder.build()).thenReturn(histogram);
        return histogram;
    }
}
