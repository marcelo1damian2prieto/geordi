package io.geordi.traces.domain;

import java.util.Objects;

public record SpanService(
        String name,
        String namespace,
        String environment,
        TelemetryOrigin telemetryOrigin) {

    public SpanService {
        name = normalize(name);
        namespace = normalize(namespace);
        environment = normalize(environment);
        telemetryOrigin = Objects.requireNonNull(telemetryOrigin, "telemetry origin must not be null");
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
