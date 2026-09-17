package io.geordi.slos.application;

import java.time.Duration;
import java.util.Map;
import java.util.Objects;

public record BoundedRequestOutcomeMeasurement(Map<Duration, RequestOutcomeMeasurement> measurements) {

    public BoundedRequestOutcomeMeasurement {
        measurements = Map.copyOf(Objects.requireNonNull(measurements, "measurements must not be null"));
    }
}
