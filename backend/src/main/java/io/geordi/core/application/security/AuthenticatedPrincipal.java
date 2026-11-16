package io.geordi.core.application.security;

import java.util.Objects;
import java.util.Set;

public record AuthenticatedPrincipal(PrincipalIdentity identity, String displayName,
        Set<GeordiPermission> permissions, AuthenticationMechanism mechanism) {
    public AuthenticatedPrincipal {
        Objects.requireNonNull(identity, "identity required");
        Objects.requireNonNull(mechanism, "mechanism required");
        permissions = Set.copyOf(permissions);
        if (displayName != null && (displayName.isEmpty()
                || displayName.codePointCount(0, displayName.length()) > 128
                || displayName.codePoints().anyMatch(value -> Character.isISOControl(value)
                        || value >= Character.MIN_SURROGATE && value <= Character.MAX_SURROGATE))) {
            displayName = null;
        }
    }

    @Override
    public String toString() {
        return "AuthenticatedPrincipal[" + mechanism + "]";
    }
}
