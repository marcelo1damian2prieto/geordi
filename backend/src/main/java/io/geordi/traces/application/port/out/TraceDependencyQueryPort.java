package io.geordi.traces.application.port.out;

import io.geordi.traces.application.TraceDependencyQuery;
import io.geordi.traces.domain.TraceCandidateBatch;

public interface TraceDependencyQueryPort {

    TraceCandidateBatch findDependencyCandidates(TraceDependencyQuery query);
}
