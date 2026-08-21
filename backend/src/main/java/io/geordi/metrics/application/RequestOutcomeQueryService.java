package io.geordi.metrics.application;

import io.geordi.metrics.application.port.out.RequestOutcomeQueryPort;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.Objects;

public final class RequestOutcomeQueryService {

    private final RequestOutcomeQueryPort port;

    public RequestOutcomeQueryService(RequestOutcomeQueryPort port) {
        this.port = Objects.requireNonNull(port, "request outcome query port must not be null");
    }

    public RequestOutcomeMeasurement measure(ServiceIdentity service, TimeRange range) {
        return port.query(new RequestOutcomeQuery(service, range));
    }
}
