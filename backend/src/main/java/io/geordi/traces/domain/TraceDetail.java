package io.geordi.traces.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public final class TraceDetail {

    private static final Comparator<TraceSpan> SPAN_ORDER = Comparator.comparing(TraceSpan::startTime)
            .thenComparing(TraceSpan::spanId);

    private final TraceId traceId;
    private final Instant startTime;
    private final Duration duration;
    private final List<TraceSpanNode> spans;
    private final boolean error;
    private final boolean monitoredSpan;

    public TraceDetail(TraceId traceId, List<TraceSpan> sourceSpans) {
        this.traceId = Objects.requireNonNull(traceId, "trace id must not be null");
        if (sourceSpans == null || sourceSpans.isEmpty()) {
            throw new IllegalArgumentException("trace detail must contain spans");
        }
        List<TraceSpan> copied = List.copyOf(sourceSpans);
        Map<SpanId, TraceSpan> byId = indexAndValidate(copied);
        validateAcyclic(byId);
        startTime = copied.stream().map(TraceSpan::startTime).min(Instant::compareTo).orElseThrow();
        Instant endTime = copied.stream().map(TraceDetail::endTime).max(Instant::compareTo).orElseThrow();
        duration = Duration.between(startTime, endTime);
        spans = order(copied, byId, startTime);
        error = copied.stream().anyMatch(span -> span.service().telemetryOrigin() == TelemetryOrigin.MONITORED
                && span.error());
        monitoredSpan = copied.stream().anyMatch(span -> span.service().telemetryOrigin() == TelemetryOrigin.MONITORED);
    }

    public TraceId traceId() {
        return traceId;
    }

    public Instant startTime() {
        return startTime;
    }

    public Duration duration() {
        return duration;
    }

    public List<TraceSpanNode> spans() {
        return spans;
    }

    public int spanCount() {
        return spans.size();
    }

    public boolean error() {
        return error;
    }

    public boolean hasMonitoredSpan() {
        return monitoredSpan;
    }

    private Map<SpanId, TraceSpan> indexAndValidate(List<TraceSpan> sourceSpans) {
        Map<SpanId, TraceSpan> byId = new HashMap<>();
        for (TraceSpan span : sourceSpans) {
            if (!traceId.equals(span.traceId())) {
                throw new IllegalArgumentException("span belongs to a different trace");
            }
            if (byId.putIfAbsent(span.spanId(), span) != null) {
                throw new IllegalArgumentException("trace contains a duplicate span id");
            }
        }
        return Map.copyOf(byId);
    }

    private static void validateAcyclic(Map<SpanId, TraceSpan> byId) {
        Set<SpanId> complete = new HashSet<>();
        for (TraceSpan span : byId.values()) {
            Set<SpanId> path = new HashSet<>();
            TraceSpan current = span;
            while (current != null && !complete.contains(current.spanId())) {
                if (!path.add(current.spanId())) {
                    throw new IllegalArgumentException("trace contains a parent cycle");
                }
                current = current.parentSpanId() == null ? null : byId.get(current.parentSpanId());
            }
            complete.addAll(path);
        }
    }

    private static List<TraceSpanNode> order(
            List<TraceSpan> sourceSpans, Map<SpanId, TraceSpan> byId, Instant traceStart) {
        Map<SpanId, List<TraceSpan>> children = new HashMap<>();
        List<TraceSpan> roots = new ArrayList<>();
        for (TraceSpan span : sourceSpans) {
            if (span.parentSpanId() == null || !byId.containsKey(span.parentSpanId())) {
                roots.add(span);
            } else {
                children.computeIfAbsent(span.parentSpanId(), ignored -> new ArrayList<>()).add(span);
            }
        }
        roots.sort(SPAN_ORDER);
        children.values().forEach(items -> items.sort(SPAN_ORDER));
        List<TraceSpanNode> ordered = new ArrayList<>(sourceSpans.size());
        for (TraceSpan root : roots) {
            append(root, 0, traceStart, children, ordered);
        }
        return List.copyOf(ordered);
    }

    private static void append(
            TraceSpan span,
            int depth,
            Instant traceStart,
            Map<SpanId, List<TraceSpan>> children,
            List<TraceSpanNode> ordered) {
        long offset = Duration.between(traceStart, span.startTime()).toNanos();
        ordered.add(new TraceSpanNode(span, depth, offset));
        for (TraceSpan child : children.getOrDefault(span.spanId(), List.of())) {
            append(child, depth + 1, traceStart, children, ordered);
        }
    }

    private static Instant endTime(TraceSpan span) {
        return span.startTime().plus(span.duration());
    }
}
