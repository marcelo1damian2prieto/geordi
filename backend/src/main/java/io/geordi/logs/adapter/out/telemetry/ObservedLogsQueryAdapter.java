package io.geordi.logs.adapter.out.telemetry;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.port.out.LogsBackendProbe;
import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.List;
import java.util.Objects;
import java.util.function.Supplier;

public final class ObservedLogsQueryAdapter implements LogsQueryPort, LogsBackendProbe {

    private static final AttributeKey<String> OPERATION = AttributeKey.stringKey("geordi.logs.operation");

    private final LogsQueryPort queryDelegate;
    private final LogsBackendProbe probeDelegate;
    private final LongCounter requests;
    private final LongCounter failures;
    private final LongCounter results;
    private final LongCounter probeAvailability;
    private final DoubleHistogram duration;

    public ObservedLogsQueryAdapter(LogsQueryPort queryDelegate, LogsBackendProbe probeDelegate) {
        this.queryDelegate = Objects.requireNonNull(queryDelegate, "logs query delegate must not be null");
        this.probeDelegate = Objects.requireNonNull(probeDelegate, "logs probe delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.logs");
        requests = meter.counterBuilder("geordi.logs.backend.requests").build();
        failures = meter.counterBuilder("geordi.logs.backend.failures").build();
        results = meter.counterBuilder("geordi.logs.backend.results").build();
        probeAvailability = meter.counterBuilder("geordi.logs.backend.probe").build();
        duration = meter.histogramBuilder("geordi.logs.backend.duration").setUnit("s").build();
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        return observe("services", () -> queryDelegate.findServices(range));
    }

    @Override
    public List<LogRecord> search(LogSearchCriteria criteria) {
        return observe("search", () -> queryDelegate.search(criteria));
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
                .put(AttributeKey.booleanKey("geordi.logs.available"), available)
                .build());
        return available;
    }

    private <T> List<T> observe(String operation, Supplier<List<T>> action) {
        Attributes attributes = attributes(operation);
        requests.add(1, attributes);
        long started = System.nanoTime();
        try {
            List<T> result = action.get();
            results.add(result.size(), attributes);
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
}
