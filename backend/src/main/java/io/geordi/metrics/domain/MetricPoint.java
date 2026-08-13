package io.geordi.metrics.domain;

import java.time.Instant;
import java.util.Objects;

public record MetricPoint(Instant timestamp, double value) {

    public MetricPoint {
        Objects.requireNonNull(timestamp, "point timestamp must not be null");
        if (!Double.isFinite(value)) {
            throw new IllegalArgumentException("point value must be finite");
        }
    }
}
