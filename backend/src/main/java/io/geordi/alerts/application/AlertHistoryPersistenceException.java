package io.geordi.alerts.application;

import java.util.Objects;

public final class AlertHistoryPersistenceException extends RuntimeException {

    public enum Kind {
        PERSISTENCE,
        INVARIANT
    }

    private final Kind kind;

    public AlertHistoryPersistenceException(Kind kind, String message, Throwable cause) {
        super(message, cause);
        this.kind = Objects.requireNonNull(kind, "alert history failure kind must not be null");
    }

    public Kind kind() {
        return kind;
    }
}
