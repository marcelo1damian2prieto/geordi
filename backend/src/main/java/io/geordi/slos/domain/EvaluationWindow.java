package io.geordi.slos.domain;

import java.time.Duration;
import java.util.Arrays;

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

    public static EvaluationWindow from(String value) {
        return Arrays.stream(values())
                .filter(window -> window.value().equals(value))
                .findFirst()
                .orElseThrow(() -> new IllegalArgumentException("unsupported SLO window"));
    }
}
