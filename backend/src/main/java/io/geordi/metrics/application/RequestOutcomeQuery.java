package io.geordi.metrics.application;

import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.Objects;

public record RequestOutcomeQuery(ServiceIdentity service, TimeRange range) {

    public RequestOutcomeQuery {
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(range, "range must not be null");
    }
}
