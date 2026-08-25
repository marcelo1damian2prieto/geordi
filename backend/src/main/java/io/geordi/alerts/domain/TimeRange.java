package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;

public record TimeRange(Instant from, Instant to) {

    public TimeRange {
        Objects.requireNonNull(from, "range start must not be null");
        Objects.requireNonNull(to, "range end must not be null");
        if (!from.isBefore(to)) {
            throw new IllegalArgumentException("range start must be before range end");
        }
    }
}
