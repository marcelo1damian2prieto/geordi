package io.geordi.slos.application;

import java.time.Duration;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.Set;

public record BoundedObservationWindowRequest(List<Duration> observationWindows) {

    private static final List<Duration> SUPPORTED_WINDOWS = List.of(
            Duration.ofMinutes(5), Duration.ofMinutes(30), Duration.ofHours(1), Duration.ofHours(6));

    public BoundedObservationWindowRequest(Collection<Duration> observationWindows) {
        this(canonical(observationWindows));
    }

    public BoundedObservationWindowRequest {
        observationWindows = List.copyOf(Objects.requireNonNull(
                observationWindows, "observation windows must not be null"));
        if (observationWindows.size() < 2 || observationWindows.size() > 4) {
            throw new IllegalArgumentException("two through four observation windows are required");
        }
        if (Set.copyOf(observationWindows).size() != observationWindows.size()) {
            throw new IllegalArgumentException("observation windows must be unique");
        }
        if (!SUPPORTED_WINDOWS.containsAll(observationWindows)) {
            throw new IllegalArgumentException("unsupported observation window");
        }
        if (!observationWindows.equals(canonical(observationWindows))) {
            throw new IllegalArgumentException("observation windows must use canonical order");
        }
    }

    private static List<Duration> canonical(Collection<Duration> windows) {
        Objects.requireNonNull(windows, "observation windows must not be null");
        return windows.stream()
                .map(window -> Objects.requireNonNull(window, "observation window must not be null"))
                .sorted(Comparator.comparingInt(SUPPORTED_WINDOWS::indexOf))
                .toList();
    }
}
