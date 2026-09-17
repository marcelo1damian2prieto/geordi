package io.geordi.metrics.application;

import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;

public record RequestOutcomeBatchQuery(ServiceIdentity service, List<Window> windows) {

    public RequestOutcomeBatchQuery {
        Objects.requireNonNull(service, "service must not be null");
        windows = List.copyOf(Objects.requireNonNull(windows, "windows must not be null"));
        if (windows.size() < 2 || windows.size() > 4) {
            throw new IllegalArgumentException("two through four request outcome windows are required");
        }
        if (new HashSet<>(windows.stream().map(Window::correlationKey).toList()).size() != windows.size()) {
            throw new IllegalArgumentException("request outcome correlation keys must be unique");
        }
        var evaluatedAt = windows.getFirst().range().to();
        if (windows.stream().anyMatch(window -> !window.range().to().equals(evaluatedAt))) {
            throw new IllegalArgumentException("request outcome windows must share one evaluation instant");
        }
    }

    public record Window(String correlationKey, TimeRange range) {

        public Window {
            if (correlationKey == null || !correlationKey.matches("[A-Za-z0-9_]{1,16}")) {
                throw new IllegalArgumentException("bounded correlation key is invalid");
            }
            Objects.requireNonNull(range, "range must not be null");
        }
    }
}
