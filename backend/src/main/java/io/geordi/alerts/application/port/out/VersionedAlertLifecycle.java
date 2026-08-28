package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertLifecycle;
import java.util.Objects;

public record VersionedAlertLifecycle(AlertLifecycle lifecycle, long version) {

    public VersionedAlertLifecycle {
        Objects.requireNonNull(lifecycle, "versioned lifecycle must not be null");
        if (version < 0) {
            throw new IllegalArgumentException("lifecycle version must not be negative");
        }
    }
}
