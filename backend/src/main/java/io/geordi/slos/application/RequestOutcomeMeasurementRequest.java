package io.geordi.slos.application;

import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.TimeRange;
import java.util.Objects;

public record RequestOutcomeMeasurementRequest(ServiceIdentity service, TimeRange range) {

    public RequestOutcomeMeasurementRequest {
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(range, "range must not be null");
    }
}
