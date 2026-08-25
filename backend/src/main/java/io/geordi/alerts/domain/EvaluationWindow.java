package io.geordi.alerts.domain;

import java.time.Duration;

public enum EvaluationWindow {
    PT5M(Duration.ofMinutes(5)),
    PT15M(Duration.ofMinutes(15)),
    PT1H(Duration.ofHours(1)),
    PT6H(Duration.ofHours(6));

    private final Duration duration;

    EvaluationWindow(Duration duration) {
        this.duration = duration;
    }

    public Duration duration() {
        return duration;
    }

    public String value() {
        return name();
    }
}
