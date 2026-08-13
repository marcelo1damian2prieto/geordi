package io.geordi.traces.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.Objects;

public record TraceSpan(
        TraceId traceId,
        SpanId spanId,
        SpanId parentSpanId,
        String name,
        SpanService service,
        SpanKind kind,
        SpanStatus status,
        Instant startTime,
        Duration duration,
        String errorType,
        HttpMetadata http) {

    public TraceSpan {
        Objects.requireNonNull(traceId, "trace id must not be null");
        Objects.requireNonNull(spanId, "span id must not be null");
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("span name must not be blank");
        }
        name = name.trim();
        Objects.requireNonNull(service, "span service must not be null");
        Objects.requireNonNull(kind, "span kind must not be null");
        Objects.requireNonNull(status, "span status must not be null");
        Objects.requireNonNull(startTime, "span start time must not be null");
        Objects.requireNonNull(duration, "span duration must not be null");
        if (duration.isNegative()) {
            throw new IllegalArgumentException("span duration must not be negative");
        }
        errorType = errorType == null || errorType.isBlank() ? null : errorType.trim();
        if (http != null && http.isEmpty()) {
            http = null;
        }
    }

    public boolean error() {
        if (status == SpanStatus.ERROR) {
            return true;
        }
        if (status == SpanStatus.OK) {
            return false;
        }
        if (errorType != null) {
            return true;
        }
        if (http == null || http.responseStatusCode() == null) {
            return false;
        }
        return kind == SpanKind.SERVER
                ? http.responseStatusCode() >= 500
                : kind == SpanKind.CLIENT && http.responseStatusCode() >= 400;
    }
}
