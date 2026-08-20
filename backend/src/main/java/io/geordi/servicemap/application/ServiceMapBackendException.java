package io.geordi.servicemap.application;

import java.util.Objects;

public final class ServiceMapBackendException extends RuntimeException {

    private final Reason reason;

    public ServiceMapBackendException(Reason reason, String message) {
        super(message);
        this.reason = Objects.requireNonNull(reason, "failure reason must not be null");
    }

    public ServiceMapBackendException(Reason reason, String message, Throwable cause) {
        super(message, cause);
        this.reason = Objects.requireNonNull(reason, "failure reason must not be null");
    }

    public Reason reason() {
        return reason;
    }

    public enum Reason {
        UNAVAILABLE,
        TIMEOUT,
        MALFORMED_RESPONSE
    }
}
