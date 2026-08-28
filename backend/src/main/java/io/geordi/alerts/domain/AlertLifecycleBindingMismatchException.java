package io.geordi.alerts.domain;

public final class AlertLifecycleBindingMismatchException extends RuntimeException {

    public AlertLifecycleBindingMismatchException() {
        super("alert lifecycle identity conflicts with canonical evaluation");
    }
}
