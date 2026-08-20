package io.geordi.servicemap.domain;

import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

public record CandidateTraceBatch(List<CandidateTrace> traces, boolean truncated) {

    public CandidateTraceBatch {
        traces = List.copyOf(Objects.requireNonNull(traces, "candidate traces must not be null"));
        Set<TraceId> identifiers = new HashSet<>();
        if (traces.stream().anyMatch(trace -> !identifiers.add(trace.traceId()))) {
            throw new IllegalArgumentException("candidate traces must have distinct trace ids");
        }
        if (traces.size() > 50) {
            throw new IllegalArgumentException("candidate trace batch must not exceed 50 traces");
        }
    }
}
