package io.geordi.logs.application;

public final class LogsBackendException extends RuntimeException {

    private final Reason reason;

    public LogsBackendException(Reason reason, String message) {
        super(message);
        this.reason = reason;
    }

    public LogsBackendException(Reason reason, String message, Throwable cause) {
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
