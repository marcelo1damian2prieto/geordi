package io.geordi.servicemap.adapter.out.telemetry;

import io.geordi.servicemap.application.ServiceMapBackendException;
import io.geordi.servicemap.application.ServiceMapQuery;
import io.geordi.servicemap.application.ServiceMapUseCase;
import io.geordi.servicemap.domain.ServiceMapResult;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Objects;

public final class ObservedServiceMapUseCase implements ServiceMapUseCase {

    private static final AttributeKey<String> OUTCOME = AttributeKey.stringKey("geordi.service_map.outcome");
    private static final AttributeKey<String> NODES_BUCKET = AttributeKey.stringKey("geordi.service_map.nodes.bucket");
    private static final AttributeKey<String> EDGES_BUCKET = AttributeKey.stringKey("geordi.service_map.edges.bucket");
    private static final AttributeKey<Boolean> TRUNCATED = AttributeKey.booleanKey("geordi.service_map.truncated");

    private final ServiceMapUseCase delegate;
    private final LongCounter queries;
    private final LongCounter failures;
    private final LongCounter results;
    private final LongCounter truncations;
    private final DoubleHistogram duration;

    public ObservedServiceMapUseCase(ServiceMapUseCase delegate) {
        this.delegate = Objects.requireNonNull(delegate, "service map delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.servicemap");
        queries = meter.counterBuilder("geordi.service_map.queries").build();
        failures = meter.counterBuilder("geordi.service_map.failures").build();
        results = meter.counterBuilder("geordi.service_map.results").build();
        truncations = meter.counterBuilder("geordi.service_map.truncations").build();
        duration = meter.histogramBuilder("geordi.service_map.duration").setUnit("s").build();
    }

    @Override
    public ServiceMapResult query(ServiceMapQuery query) {
        queries.add(1);
        long started = System.nanoTime();
        String outcome = "success";
        try {
            ServiceMapResult result = delegate.query(query);
            Attributes attributes = Attributes.builder()
                    .put(OUTCOME, outcome)
                    .put(NODES_BUCKET, sizeBucket(result.nodes().size(), 50))
                    .put(EDGES_BUCKET, sizeBucket(result.edges().size(), 100))
                    .put(TRUNCATED, result.truncated())
                    .build();
            results.add(1, attributes);
            if (result.truncated()) {
                truncations.add(1);
            }
            return result;
        } catch (ServiceMapBackendException exception) {
            outcome = exception.reason().name().toLowerCase(java.util.Locale.ROOT);
            failures.add(1, Attributes.of(OUTCOME, outcome));
            throw exception;
        } catch (RuntimeException exception) {
            outcome = "internal";
            failures.add(1, Attributes.of(OUTCOME, outcome));
            throw exception;
        } finally {
            duration.record(
                    (System.nanoTime() - started) / 1_000_000_000.0,
                    Attributes.of(OUTCOME, outcome));
        }
    }

    private static String sizeBucket(int size, int cap) {
        if (size == 0) {
            return "empty";
        }
        if (size >= cap) {
            return "cap";
        }
        return size <= 10 ? "small" : "medium";
    }
}
