package io.geordi.traces.domain;

import java.util.List;
import java.util.Objects;

public record TraceCandidateBatch(List<TraceDetail> traces, boolean truncated) {

    public TraceCandidateBatch {
        traces = List.copyOf(Objects.requireNonNull(traces, "candidate traces must not be null"));
        if (traces.size() > 50) {
            throw new IllegalArgumentException("candidate trace batch must not exceed 50 traces");
        }
    }
}
