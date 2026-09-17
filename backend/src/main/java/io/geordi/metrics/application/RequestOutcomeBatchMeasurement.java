package io.geordi.metrics.application;

import java.util.Map;
import java.util.Objects;

public record RequestOutcomeBatchMeasurement(Map<String, RequestOutcomeMeasurement> measurements) {

    public RequestOutcomeBatchMeasurement {
        measurements = Map.copyOf(Objects.requireNonNull(measurements, "measurements must not be null"));
    }
}
