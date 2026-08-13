package io.geordi.traces.application;

import io.geordi.traces.domain.TraceId;

public final class TraceNotFoundException extends RuntimeException {

    public TraceNotFoundException(TraceId traceId) {
        super("Trace not found: " + traceId.value());
    }
}
