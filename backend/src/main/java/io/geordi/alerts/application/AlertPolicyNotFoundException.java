package io.geordi.alerts.application;

public final class AlertPolicyNotFoundException extends RuntimeException {

    public AlertPolicyNotFoundException() {
        super("Alert policy not found");
    }
}
