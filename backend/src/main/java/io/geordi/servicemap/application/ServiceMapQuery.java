package io.geordi.servicemap.application;

import io.geordi.servicemap.domain.TimeRange;
import java.util.Objects;

public record ServiceMapQuery(String environment, TimeRange range) {

    public ServiceMapQuery {
        if (environment == null || environment.isBlank()) {
            throw new IllegalArgumentException("environment must not be blank");
        }
        environment = environment.trim();
        Objects.requireNonNull(range, "range must not be null");
    }
}
