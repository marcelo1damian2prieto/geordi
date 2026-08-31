package io.geordi.alerts.adapter.out.config;

import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.scheduling.alert", ignoreUnknownFields = false)
public record AlertSchedulingProperties(
        boolean enabled, Duration interval, Integer workerCount, Integer queueCapacity, Duration shutdownGracePeriod) {
    public AlertSchedulingProperties {
        interval = interval == null ? Duration.ofMinutes(1) : interval;
        workerCount = workerCount == null ? 2 : workerCount;
        queueCapacity = queueCapacity == null ? 10 : queueCapacity;
        shutdownGracePeriod = shutdownGracePeriod == null ? Duration.ofSeconds(5) : shutdownGracePeriod;
        if (interval.compareTo(Duration.ofSeconds(10)) < 0 || interval.compareTo(Duration.ofMinutes(15)) > 0) {
            throw new IllegalArgumentException("alert scheduling interval must be between 10 seconds and 15 minutes");
        }
        if (workerCount < 1 || workerCount > 4 || queueCapacity < 0 || queueCapacity > 50) {
            throw new IllegalArgumentException("alert scheduling execution bounds are invalid");
        }
        if (shutdownGracePeriod.compareTo(Duration.ofSeconds(1)) < 0
                || shutdownGracePeriod.compareTo(Duration.ofSeconds(30)) > 0) {
            throw new IllegalArgumentException("alert scheduling shutdown grace period must be between 1 and 30 seconds");
        }
    }
}
