package io.geordi.metrics.adapter.out.telemetry;

import io.geordi.metrics.application.RequestOutcomeMeasurement;
import io.geordi.metrics.application.RequestOutcomeQuery;
import io.geordi.metrics.application.RequestOutcomeBatchMeasurement;
import io.geordi.metrics.application.RequestOutcomeBatchQuery;
import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.application.port.out.RequestOutcomeBatchQueryPort;
import io.geordi.metrics.application.port.out.RequestOutcomeQueryPort;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Objects;

public final class ObservedRequestOutcomeQueryAdapter implements RequestOutcomeQueryPort, RequestOutcomeBatchQueryPort {

    private final RequestOutcomeQueryPort delegate;
    private final RequestOutcomeBatchQueryPort batchDelegate;
    private final LongCounter requests;
    private final LongCounter failures;
    private final LongCounter integrityFailures;
    private final DoubleHistogram duration;

    public ObservedRequestOutcomeQueryAdapter(RequestOutcomeQueryPort delegate) {
        this(delegate, query -> {
            throw new RequestOutcomeQueryException(
                    RequestOutcomeQueryException.Reason.UNAVAILABLE,
                    "Bounded request outcome query is unavailable");
        });
    }

    public ObservedRequestOutcomeQueryAdapter(
            RequestOutcomeQueryPort delegate, RequestOutcomeBatchQueryPort batchDelegate) {
        this.delegate = Objects.requireNonNull(delegate, "request outcome delegate must not be null");
        this.batchDelegate = Objects.requireNonNull(batchDelegate, "request outcome batch delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.metrics");
        requests = meter.counterBuilder("geordi.metrics.request_outcomes.requests").build();
        failures = meter.counterBuilder("geordi.metrics.request_outcomes.failures").build();
        integrityFailures = meter.counterBuilder("geordi.metrics.request_outcomes.integrity.failures").build();
        duration = meter.histogramBuilder("geordi.metrics.request_outcomes.duration").setUnit("s").build();
    }

    @Override
    public RequestOutcomeMeasurement query(RequestOutcomeQuery query) {
        return observed(() -> delegate.query(query));
    }

    @Override
    public RequestOutcomeBatchMeasurement queryBatch(RequestOutcomeBatchQuery query) {
        return observed(() -> batchDelegate.queryBatch(query));
    }

    private <T> T observed(java.util.function.Supplier<T> operation) {
        requests.add(1);
        long started = System.nanoTime();
        try {
            return operation.get();
        } catch (RequestOutcomeQueryException exception) {
            failures.add(1);
            if (exception.reason() == RequestOutcomeQueryException.Reason.INTEGRITY) {
                integrityFailures.add(1);
            }
            throw exception;
        } catch (RuntimeException exception) {
            failures.add(1);
            throw exception;
        } finally {
            duration.record((System.nanoTime() - started) / 1_000_000_000.0, Attributes.empty());
        }
    }
}
