package io.geordi.traces.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.Objects;

public record TimeRange(Instant from, Instant to) {

    public static final Duration MAXIMUM = Duration.ofHours(6);

    public TimeRange {
        Objects.requireNonNull(from, "range start must not be null");
        Objects.requireNonNull(to, "range end must not be null");
        Duration duration = Duration.between(from, to);
        if (duration.isNegative() || duration.isZero()) {
            throw new IllegalArgumentException("range start must be before range end");
        }
        if (duration.compareTo(MAXIMUM) > 0) {
            throw new IllegalArgumentException("range must not exceed six hours");
        }
    }

    public boolean contains(Instant instant) {
        Objects.requireNonNull(instant, "instant must not be null");
        return !instant.isBefore(from) && instant.isBefore(to);
    }
}
