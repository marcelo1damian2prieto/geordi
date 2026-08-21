package io.geordi.metrics.application.port.out;

import io.geordi.metrics.application.RequestOutcomeMeasurement;
import io.geordi.metrics.application.RequestOutcomeQuery;

@FunctionalInterface
public interface RequestOutcomeQueryPort {

    RequestOutcomeMeasurement query(RequestOutcomeQuery query);
}
