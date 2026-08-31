package io.geordi.alerts.application;

import java.time.Duration;
import java.util.Objects;

public record AlertSchedulingSettings(
        Duration interval, int workerCount, int queueCapacity, Duration shutdownGracePeriod) {
    public AlertSchedulingSettings {
        Objects.requireNonNull(interval, "interval must not be null");
        Objects.requireNonNull(shutdownGracePeriod, "shutdown grace period must not be null");
    }
}
