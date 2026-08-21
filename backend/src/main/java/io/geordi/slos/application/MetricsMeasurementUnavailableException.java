package io.geordi.slos.application;

public final class MetricsMeasurementUnavailableException extends RuntimeException {

    public MetricsMeasurementUnavailableException(String message) {
        super(message);
    }

    public MetricsMeasurementUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
