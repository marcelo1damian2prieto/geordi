package io.geordi.logs.domain;

import java.time.Instant;
import java.util.Collections;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;

public record LogRecord(
        Instant timestamp,
        Instant observedTimestamp,
        LogSeverity severity,
        String severityText,
        String body,
        ServiceIdentity service,
        TraceId traceId,
        SpanId spanId,
        Map<String, String> attributes) {

    public LogRecord {
        Objects.requireNonNull(timestamp, "log timestamp must not be null");
        Objects.requireNonNull(severity, "log severity must not be null");
        Objects.requireNonNull(service, "log service must not be null");
        if (spanId != null && traceId == null) {
            throw new IllegalArgumentException("span id requires trace id");
        }
        severityText = normalize(severityText);
        body = body == null ? "" : body;
        TreeMap<String, String> copied = new TreeMap<>();
        if (attributes != null) {
            attributes.forEach((key, value) -> copied.put(
                    Objects.requireNonNull(key, "attribute key must not be null"),
                    Objects.requireNonNull(value, "attribute value must not be null")));
        }
        attributes = Collections.unmodifiableMap(copied);
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
