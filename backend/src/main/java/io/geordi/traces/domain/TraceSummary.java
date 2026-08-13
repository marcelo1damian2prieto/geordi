package io.geordi.traces.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.Objects;

public record TraceSummary(
        TraceId traceId,
        String rootServiceName,
        String rootSpanName,
        Instant startTime,
        Duration duration,
        int spanCount,
        boolean error) {

    public TraceSummary {
        Objects.requireNonNull(traceId, "trace id must not be null");
        rootServiceName = normalize(rootServiceName);
        if (rootSpanName == null || rootSpanName.isBlank()) {
            throw new IllegalArgumentException("root span name must not be blank");
        }
        rootSpanName = rootSpanName.trim();
        Objects.requireNonNull(startTime, "trace start time must not be null");
        Objects.requireNonNull(duration, "trace duration must not be null");
        if (duration.isNegative() || spanCount < 1) {
            throw new IllegalArgumentException("trace summary values are invalid");
        }
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
