package io.geordi.logs.application;

import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TimeRange;
import io.geordi.logs.domain.TraceId;
import java.util.Objects;

public record LogSearchCriteria(
        ServiceIdentity service,
        TimeRange range,
        LogSeverity severity,
        String text,
        TraceId traceId,
        SpanId spanId,
        int limit) {

    public static final int DEFAULT_LIMIT = 100;
    public static final int MAXIMUM_LIMIT = 200;
    public static final int MAXIMUM_TEXT_LENGTH = 256;

    public LogSearchCriteria {
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(range, "range must not be null");
        text = normalize(text);
        if (text != null && text.length() > MAXIMUM_TEXT_LENGTH) {
            throw new IllegalArgumentException("text filter must not exceed 256 characters");
        }
        if (spanId != null && traceId == null) {
            throw new IllegalArgumentException("span id requires trace id");
        }
        if (limit < 1 || limit > MAXIMUM_LIMIT) {
            throw new IllegalArgumentException("limit must be between one and 200");
        }
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
