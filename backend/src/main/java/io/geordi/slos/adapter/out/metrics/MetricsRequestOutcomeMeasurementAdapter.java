package io.geordi.slos.adapter.out.metrics;

import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.application.RequestOutcomeQueryService;
import io.geordi.slos.application.MetricsMeasurementUnavailableException;
import io.geordi.slos.application.RequestOutcomeMeasurement;
import io.geordi.slos.application.RequestOutcomeMeasurementRequest;
import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
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
}
