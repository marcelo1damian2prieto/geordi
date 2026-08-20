package io.geordi.traces.application;

import io.geordi.traces.domain.TimeRange;
import java.util.Objects;

public record TraceDependencyQuery(String environment, TimeRange range) {

    public TraceDependencyQuery {
        if (environment == null || environment.isBlank()) {
            throw new IllegalArgumentException("environment must not be blank");
        }
        environment = environment.trim();
        Objects.requireNonNull(range, "range must not be null");
    }
}
