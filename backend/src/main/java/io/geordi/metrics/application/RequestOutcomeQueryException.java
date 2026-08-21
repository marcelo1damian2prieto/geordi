package io.geordi.metrics.application;

import java.util.Objects;

public final class RequestOutcomeQueryException extends RuntimeException {

    private final Reason reason;

    public RequestOutcomeQueryException(Reason reason, String message) {
        super(message);
        this.reason = Objects.requireNonNull(reason, "reason must not be null");
    }

    public RequestOutcomeQueryException(Reason reason, String message, Throwable cause) {
        super(message, cause);
        this.reason = Objects.requireNonNull(reason, "reason must not be null");
    }

    public Reason reason() {
        return reason;
    }

    public enum Reason {
        INVALID_TELEMETRY,
        UNAVAILABLE
    }
}
