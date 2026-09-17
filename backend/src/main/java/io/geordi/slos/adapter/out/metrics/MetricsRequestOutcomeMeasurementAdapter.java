package io.geordi.slos.adapter.out.metrics;

import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.application.RequestOutcomeQueryService;
import io.geordi.metrics.application.RequestOutcomeBatchQuery;
import io.geordi.slos.application.MetricsMeasurementUnavailableException;
import io.geordi.slos.application.BoundedRequestOutcomeMeasurement;
import io.geordi.slos.application.BoundedRequestOutcomeMeasurementRequest;
import io.geordi.slos.application.RequestOutcomeMeasurement;
import io.geordi.slos.application.RequestOutcomeMeasurementRequest;
import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

public final class MetricsRequestOutcomeMeasurementAdapter implements RequestOutcomeMeasurementPort {

    private final RequestOutcomeQueryService metrics;

    public MetricsRequestOutcomeMeasurementAdapter(RequestOutcomeQueryService metrics) {
        this.metrics = Objects.requireNonNull(metrics, "Metrics request outcome service must not be null");
    }

    @Override
    public RequestOutcomeMeasurement measure(RequestOutcomeMeasurementRequest request) {
        try {
            var result = metrics.measure(
                    new io.geordi.metrics.domain.ServiceIdentity(
                            request.service().name(), request.service().namespace(), request.service().environment()),
                    new io.geordi.metrics.domain.TimeRange(request.range().from(), request.range().to()));
            return new RequestOutcomeMeasurement(result.requestCount(), result.errorCount());
        } catch (RequestOutcomeQueryException exception) {
            if (exception.reason() == RequestOutcomeQueryException.Reason.INVALID_TELEMETRY) {
                return new RequestOutcomeMeasurement(Double.NaN, Double.NaN);
            }
            throw new MetricsMeasurementUnavailableException("Metrics request outcomes are unavailable", exception);
        }
    }

    @Override
    public BoundedRequestOutcomeMeasurement measureBounded(BoundedRequestOutcomeMeasurementRequest request) {
        Objects.requireNonNull(request, "bounded request outcome measurement request must not be null");
        Map<Duration, String> correlationKeys = new LinkedHashMap<>();
        var windows = request.ranges().entrySet().stream()
                .map(entry -> {
                    String correlationKey = correlationKey(entry.getKey());
                    correlationKeys.put(entry.getKey(), correlationKey);
                    return new RequestOutcomeBatchQuery.Window(
                            correlationKey,
                            new io.geordi.metrics.domain.TimeRange(
                                    entry.getValue().from(), entry.getValue().to()));
                })
                .toList();
        try {
            var batch = metrics.measureBatch(new RequestOutcomeBatchQuery(
                    new io.geordi.metrics.domain.ServiceIdentity(
                            request.service().name(), request.service().namespace(), request.service().environment()),
                    windows));
            if (batch == null || !correlationKeys.values().containsAll(batch.measurements().keySet())) {
                throw unavailable();
            }
            Map<Duration, RequestOutcomeMeasurement> measurements = new LinkedHashMap<>();
            for (Map.Entry<Duration, String> entry : correlationKeys.entrySet()) {
                var measurement = batch.measurements().get(entry.getValue());
                measurements.put(entry.getKey(), measurement == null
                        ? new RequestOutcomeMeasurement(null, null)
                        : new RequestOutcomeMeasurement(measurement.requestCount(), measurement.errorCount()));
            }
            return new BoundedRequestOutcomeMeasurement(measurements);
        } catch (RequestOutcomeQueryException exception) {
            throw new MetricsMeasurementUnavailableException("Bounded metrics request outcomes are unavailable", exception);
        }
    }

    private static String correlationKey(Duration window) {
        return window.toString();
    }

    private static MetricsMeasurementUnavailableException unavailable() {
        return new MetricsMeasurementUnavailableException("Bounded metrics response has invalid correlation keys");
    }
}
