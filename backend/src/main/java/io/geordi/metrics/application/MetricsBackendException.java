package io.geordi.metrics.application;

public final class MetricsBackendException extends RuntimeException {

    public MetricsBackendException(String message) {
        super(message);
    }

    public MetricsBackendException(String message, Throwable cause) {
        super(message, cause);
    }
}
