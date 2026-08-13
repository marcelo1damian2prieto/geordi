package io.geordi.traces.domain;

public record TraceSpanNode(TraceSpan span, int depth, long startOffsetNanos) {

    public TraceSpanNode {
        if (span == null || depth < 0 || startOffsetNanos < 0) {
            throw new IllegalArgumentException("trace span node is invalid");
        }
    }
}
