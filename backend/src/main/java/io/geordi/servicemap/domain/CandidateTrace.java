package io.geordi.servicemap.domain;

import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

public record CandidateTrace(TraceId traceId, List<TraceEvidenceSpan> spans) {

    public CandidateTrace {
        Objects.requireNonNull(traceId, "trace id must not be null");
        spans = List.copyOf(Objects.requireNonNull(spans, "spans must not be null"));
        Set<SpanId> identifiers = new HashSet<>();
        if (spans.stream().anyMatch(span -> !identifiers.add(span.spanId()))) {
            throw new IllegalArgumentException("candidate trace contains duplicate span ids");
        }
    }
}
