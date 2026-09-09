package io.geordi.alerts.application;

public final class AlertEpisodeAcknowledgementConflictException extends RuntimeException {
    public AlertEpisodeAcknowledgementConflictException() { super("alert episode acknowledgement conflicts with current state"); }
}
