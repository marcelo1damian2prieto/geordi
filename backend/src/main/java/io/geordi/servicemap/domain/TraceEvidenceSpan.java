package io.geordi.servicemap.domain;

import java.time.Instant;
import java.util.Objects;

public record TraceEvidenceSpan(
        SpanId spanId,
        SpanId parentSpanId,
        ServiceIdentity service,
        TelemetryOrigin telemetryOrigin,
        SpanKind kind,
        Instant startTime) {

    public TraceEvidenceSpan {
        Objects.requireNonNull(spanId, "span id must not be null");
        Objects.requireNonNull(service, "span service must not be null");
        Objects.requireNonNull(telemetryOrigin, "telemetry origin must not be null");
        Objects.requireNonNull(kind, "span kind must not be null");
        Objects.requireNonNull(startTime, "span start time must not be null");
    }
}
