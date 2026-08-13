package io.geordi.metrics.adapter.out.telemetry;

import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.application.port.out.MetricsBackendProbe;
import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.List;
import java.util.Objects;
import java.util.function.Supplier;

public final class ObservedMetricsQueryAdapter implements MetricsQueryPort, MetricsBackendProbe {

    private static final AttributeKey<String> OPERATION = AttributeKey.stringKey("geordi.metrics.operation");

    private final MetricsQueryPort queryDelegate;
    private final MetricsBackendProbe probeDelegate;
    private final LongCounter requests;
    private final LongCounter failures;
    private final LongCounter points;
    private final LongCounter probeAvailability;
    private final DoubleHistogram duration;

    public ObservedMetricsQueryAdapter(MetricsQueryPort queryDelegate, MetricsBackendProbe probeDelegate) {
        this.queryDelegate = Objects.requireNonNull(queryDelegate, "query delegate must not be null");
        this.probeDelegate = Objects.requireNonNull(probeDelegate, "probe delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.metrics");
        requests = meter.counterBuilder("geordi.metrics.backend.requests").build();
        failures = meter.counterBuilder("geordi.metrics.backend.failures").build();
        points = meter.counterBuilder("geordi.metrics.backend.result.points").build();
        probeAvailability = meter.counterBuilder("geordi.metrics.backend.probe").build();
        duration = meter.histogramBuilder("geordi.metrics.backend.duration")
                .setUnit("s").build();
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        return observe("services", () -> queryDelegate.findServices(range), List::size);
    }

    @Override
    public List<MetricSeries> query(MetricsQuery query) {
        return observe("series", () -> queryDelegate.query(query), result -> result.stream()
                .mapToInt(series -> series.points().size()).sum());
    }

    @Override
    public boolean isQueryable() {
        boolean available;
        try {
            available = probeDelegate.isQueryable();
        } catch (RuntimeException exception) {
            failures.add(1, attributes("probe"));
            available = false;
        }
        probeAvailability.add(1, Attributes.builder()
                .put(OPERATION, "probe")
                .put(AttributeKey.booleanKey("geordi.metrics.available"), available)
                .build());
        return available;
    }

    private <T> T observe(String operation, Supplier<T> action, ResultSize<T> resultSize) {
        Attributes attributes = attributes(operation);
        requests.add(1, attributes);
        long started = System.nanoTime();
        try {
            T result = action.get();
            points.add(resultSize.size(result), attributes);
            return result;
        } catch (RuntimeException exception) {
            failures.add(1, attributes);
            throw exception;
        } finally {
            duration.record((System.nanoTime() - started) / 1_000_000_000.0, attributes);
        }
    }

    private static Attributes attributes(String operation) {
        return Attributes.of(OPERATION, operation);
    }

    @FunctionalInterface
    private interface ResultSize<T> {
        int size(T result);
    }
}
