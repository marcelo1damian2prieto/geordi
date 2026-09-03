package io.geordi.alerts.application;

/** Raised only when a durable history episode cannot be found. */
public final class AlertEpisodeNotFoundException extends RuntimeException {

    public AlertEpisodeNotFoundException() {
        super("alert episode was not found");
    }
}
