package io.geordi.metrics.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.Objects;

public record TimeRange(Instant from, Instant to) {

    public static final Duration MAXIMUM = Duration.ofHours(6);
    private static final int MAXIMUM_POINTS = 300;

    public TimeRange {
        Objects.requireNonNull(from, "range start must not be null");
        Objects.requireNonNull(to, "range end must not be null");
        Duration duration = Duration.between(from, to);
        if (duration.isZero() || duration.isNegative()) {
            throw new IllegalArgumentException("range start must be before range end");
        }
        if (duration.compareTo(MAXIMUM) > 0) {
            throw new IllegalArgumentException("range must not exceed six hours");
        }
    }

    public Duration resolution() {
        long seconds = Math.max(1, Duration.between(from, to).toSeconds());
        return Duration.ofSeconds(Math.max(1, (seconds + MAXIMUM_POINTS - 1) / MAXIMUM_POINTS));
    }
}
