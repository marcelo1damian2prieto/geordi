package io.geordi.bootstrap.security;

import java.util.Objects;

/** Protocol adapters expose only bounded failures, never provider/parser exceptions. */
public final class SecurityFailure extends RuntimeException {
    public enum Kind { INVALID_AUTHENTICATION, DEPENDENCY_UNAVAILABLE, AMBIGUOUS_CREDENTIALS,
        CAPACITY_EXHAUSTED, FORBIDDEN, CSRF, ORIGIN, DENIED }

    private final Kind kind;

    public SecurityFailure(Kind kind) {
        super("Security request failed");
        this.kind = Objects.requireNonNull(kind);
    }

    public Kind kind() {
        return kind;
    }

    public static SecurityFailure invalid() {
        return new SecurityFailure(Kind.INVALID_AUTHENTICATION);
    }
}
