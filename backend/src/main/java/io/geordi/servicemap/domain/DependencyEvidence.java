package io.geordi.servicemap.domain;

import java.time.Instant;
import java.util.Objects;

public record DependencyEvidence(TraceId traceId, Instant observedAt) {

    public DependencyEvidence {
        Objects.requireNonNull(traceId, "evidence trace id must not be null");
        Objects.requireNonNull(observedAt, "evidence timestamp must not be null");
    }
}
