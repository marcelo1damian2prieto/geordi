package io.geordi.traces.application;

import io.geordi.traces.application.port.out.TraceDependencyQueryPort;
import io.geordi.traces.domain.TraceCandidateBatch;
import java.util.Objects;

public final class TraceDependencyQueryService {

    private final TraceDependencyQueryPort port;

    public TraceDependencyQueryService(TraceDependencyQueryPort port) {
        this.port = Objects.requireNonNull(port, "trace dependency query port must not be null");
    }

    public TraceCandidateBatch findCandidates(TraceDependencyQuery query) {
        return port.findDependencyCandidates(Objects.requireNonNull(query, "trace dependency query must not be null"));
    }
}
