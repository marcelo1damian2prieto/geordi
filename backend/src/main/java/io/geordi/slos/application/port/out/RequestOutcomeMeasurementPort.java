package io.geordi.slos.application.port.out;

import io.geordi.slos.application.RequestOutcomeMeasurement;
import io.geordi.slos.application.RequestOutcomeMeasurementRequest;

@FunctionalInterface
public interface RequestOutcomeMeasurementPort {

    RequestOutcomeMeasurement measure(RequestOutcomeMeasurementRequest request);
}
