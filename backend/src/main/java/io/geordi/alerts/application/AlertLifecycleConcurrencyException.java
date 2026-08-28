package io.geordi.alerts.application;

public final class AlertLifecycleConcurrencyException extends RuntimeException {

    public AlertLifecycleConcurrencyException() {
        super("alert lifecycle could not be updated after bounded retries");
    }
}
