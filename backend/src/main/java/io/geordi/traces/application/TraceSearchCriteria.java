package io.geordi.traces.application;

import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import java.util.Objects;

public record TraceSearchCriteria(ServiceIdentity service, TimeRange range, boolean errorOnly) {

    public static final int RESULT_LIMIT = 50;

    public TraceSearchCriteria {
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(range, "range must not be null");
    }

    public int limit() {
        return RESULT_LIMIT;
    }
}
