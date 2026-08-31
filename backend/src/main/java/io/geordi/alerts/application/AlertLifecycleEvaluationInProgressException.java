package io.geordi.alerts.application;

public final class AlertLifecycleEvaluationInProgressException extends RuntimeException {
    public AlertLifecycleEvaluationInProgressException() {
        super("Alert lifecycle evaluation is already in progress");
    }
}
