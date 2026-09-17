package io.geordi.metrics.application.port.out;

import io.geordi.metrics.application.RequestOutcomeBatchMeasurement;
import io.geordi.metrics.application.RequestOutcomeBatchQuery;

@FunctionalInterface
public interface RequestOutcomeBatchQueryPort {

    RequestOutcomeBatchMeasurement queryBatch(RequestOutcomeBatchQuery query);
}
