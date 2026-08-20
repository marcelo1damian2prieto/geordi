package io.geordi.traces.adapter.out.telemetry;

import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.TraceDependencyQuery;
import io.geordi.traces.application.port.out.TraceBackendProbe;
import io.geordi.traces.application.port.out.TraceDependencyQueryPort;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import io.geordi.traces.domain.TraceCandidateBatch;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.function.Supplier;
import java.util.function.ToLongFunction;

public final class ObservedTraceQueryAdapter implements TraceQueryPort, TraceBackendProbe, TraceDependencyQueryPort {

    private static final AttributeKey<String> OPERATION = AttributeKey.stringKey("geordi.traces.operation");

    private final TraceQueryPort queryDelegate;
    private final TraceBackendProbe probeDelegate;
    private final TraceDependencyQueryPort dependencyDelegate;
    private final LongCounter requests;
    private final LongCounter failures;
    private final LongCounter results;
    private final LongCounter probeAvailability;
    private final DoubleHistogram duration;

    public ObservedTraceQueryAdapter(TraceQueryPort queryDelegate, TraceBackendProbe probeDelegate) {
        this(queryDelegate, probeDelegate, query -> {
            throw new UnsupportedOperationException("trace dependency queries are not configured");
        });
    }

    public ObservedTraceQueryAdapter(
            TraceQueryPort queryDelegate,
            TraceBackendProbe probeDelegate,
            TraceDependencyQueryPort dependencyDelegate) {
        this.queryDelegate = Objects.requireNonNull(queryDelegate, "trace query delegate must not be null");
        this.probeDelegate = Objects.requireNonNull(probeDelegate, "trace probe delegate must not be null");
        this.dependencyDelegate = Objects.requireNonNull(
                dependencyDelegate, "trace dependency delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.traces");
        requests = meter.counterBuilder("geordi.traces.backend.requests").build();
        failures = meter.counterBuilder("geordi.traces.backend.failures").build();
        results = meter.counterBuilder("geordi.traces.backend.results").build();
        probeAvailability = meter.counterBuilder("geordi.traces.backend.probe").build();
        duration = meter.histogramBuilder("geordi.traces.backend.duration").setUnit("s").build();
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        return observe("services", () -> queryDelegate.findServices(range), List::size);
    }

    @Override
    public List<TraceSummary> search(TraceSearchCriteria criteria) {
        return observe("search", () -> queryDelegate.search(criteria), List::size);
    }

    @Override
    public Optional<TraceDetail> findTrace(TraceId traceId) {
        return observe("detail", () -> queryDelegate.findTrace(traceId),
                detail -> detail.map(TraceDetail::spanCount).orElse(0));
    }

    @Override
    public TraceCandidateBatch findDependencyCandidates(TraceDependencyQuery query) {
        return observe(
                "dependency-candidates",
                () -> dependencyDelegate.findDependencyCandidates(query),
                result -> result.traces().size());
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
                .put(AttributeKey.booleanKey("geordi.traces.available"), available)
                .build());
        return available;
    }

    private <T> T observe(String operation, Supplier<T> action, ToLongFunction<T> resultSize) {
        Attributes attributes = attributes(operation);
        requests.add(1, attributes);
        long started = System.nanoTime();
        try {
            T result = action.get();
            results.add(resultSize.applyAsLong(result), attributes);
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
