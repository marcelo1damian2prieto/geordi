package io.geordi.traces.application;

public final class TraceBackendException extends RuntimeException {

    private final Reason reason;

    public TraceBackendException(Reason reason, String message) {
        super(message);
        this.reason = reason;
    }

    public TraceBackendException(Reason reason, String message, Throwable cause) {
        super(message, cause);
        this.reason = reason;
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
