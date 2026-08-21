package io.geordi.metrics.adapter.out.telemetry;

import io.geordi.metrics.application.RequestOutcomeMeasurement;
import io.geordi.metrics.application.RequestOutcomeQuery;
import io.geordi.metrics.application.port.out.RequestOutcomeQueryPort;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Objects;

public final class ObservedRequestOutcomeQueryAdapter implements RequestOutcomeQueryPort {

    private final RequestOutcomeQueryPort delegate;
    private final LongCounter requests;
    private final LongCounter failures;
    private final DoubleHistogram duration;

    public ObservedRequestOutcomeQueryAdapter(RequestOutcomeQueryPort delegate) {
        this.delegate = Objects.requireNonNull(delegate, "request outcome delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.metrics");
        requests = meter.counterBuilder("geordi.metrics.request_outcomes.requests").build();
        failures = meter.counterBuilder("geordi.metrics.request_outcomes.failures").build();
        duration = meter.histogramBuilder("geordi.metrics.request_outcomes.duration").setUnit("s").build();
    }

    @Override
    public RequestOutcomeMeasurement query(RequestOutcomeQuery query) {
        requests.add(1);
        long started = System.nanoTime();
        try {
            return delegate.query(query);
        } catch (RuntimeException exception) {
            failures.add(1);
            throw exception;
        } finally {
            duration.record((System.nanoTime() - started) / 1_000_000_000.0, Attributes.empty());
        }
    }
}
