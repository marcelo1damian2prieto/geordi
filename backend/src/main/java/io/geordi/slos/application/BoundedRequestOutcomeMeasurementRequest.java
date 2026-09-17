package io.geordi.slos.application;

import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.TimeRange;
import java.time.Duration;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

public record BoundedRequestOutcomeMeasurementRequest(
        ServiceIdentity service, Map<Duration, TimeRange> ranges) {

    public BoundedRequestOutcomeMeasurementRequest {
        Objects.requireNonNull(service, "service must not be null");
        ranges = Map.copyOf(Objects.requireNonNull(ranges, "ranges must not be null"));
        BoundedObservationWindowRequest request = new BoundedObservationWindowRequest(ranges.keySet());
        Map<Duration, TimeRange> canonical = new LinkedHashMap<>();
        for (Duration window : request.observationWindows()) {
            TimeRange range = Objects.requireNonNull(ranges.get(window), "observation range must not be null");
            if (!Duration.between(range.from(), range.to()).equals(window)) {
                throw new IllegalArgumentException("observation range must match its window");
            }
            canonical.put(window, range);
        }
        ranges = Collections.unmodifiableMap(canonical);
    }
}
