package io.geordi.alerts.application;

/** Bounded integrity failure; no durable value appears in the public failure. */
public final class AlertNotificationIntegrityException extends AlertHistoryPersistenceException {
    public enum Reason {
        MATCHED_DELIVERY_MISSING, UNEXPECTED_DELIVERY, CORRELATION_INVALID, STORED_VALUE_INVALID
    }

    private final Reason reason;

    public AlertNotificationIntegrityException(Reason reason) {
        super(Kind.INVARIANT, "alert notification evidence is inconsistent", null);
        this.reason = java.util.Objects.requireNonNull(reason);
    }

    public Reason reason() { return reason; }
}
