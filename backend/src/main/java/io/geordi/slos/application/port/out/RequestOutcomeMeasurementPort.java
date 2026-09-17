package io.geordi.slos.application.port.out;

import io.geordi.slos.application.RequestOutcomeMeasurement;
import io.geordi.slos.application.RequestOutcomeMeasurementRequest;
import io.geordi.slos.application.BoundedRequestOutcomeMeasurement;
import io.geordi.slos.application.BoundedRequestOutcomeMeasurementRequest;
import io.geordi.slos.application.MetricsMeasurementUnavailableException;

@FunctionalInterface
public interface RequestOutcomeMeasurementPort {

    RequestOutcomeMeasurement measure(RequestOutcomeMeasurementRequest request);

    default BoundedRequestOutcomeMeasurement measureBounded(BoundedRequestOutcomeMeasurementRequest request) {
        throw new MetricsMeasurementUnavailableException("Bounded metrics measurement is unavailable");
    }
}
