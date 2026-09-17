package io.geordi.alerts.domain;

import java.time.Duration;
import java.util.Objects;

public enum AlertObservationWindow {
    PT5M(Duration.ofMinutes(5), 0),
    PT30M(Duration.ofMinutes(30), 1),
    PT1H(Duration.ofHours(1), 2),
    PT6H(Duration.ofHours(6), 3);

    private final Duration duration;
    private final int canonicalRank;

    AlertObservationWindow(Duration duration, int canonicalRank) {
        this.duration = duration;
        this.canonicalRank = canonicalRank;
    }

    public Duration duration() {
        return duration;
    }

    public int canonicalRank() {
        return canonicalRank;
    }

    public String value() {
        return name();
    }

    public static AlertObservationWindow from(Duration duration) {
        Objects.requireNonNull(duration, "alert observation duration must not be null");
        for (AlertObservationWindow window : values()) {
            if (window.duration.equals(duration)) {
                return window;
            }
        }
        throw new IllegalArgumentException("unsupported alert observation duration");
    }
}
