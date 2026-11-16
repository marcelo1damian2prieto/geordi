package io.geordi.core.application.security;

public final class PermissionCheck {
    private PermissionCheck() { }

    public static void require(AuthenticatedPrincipal principal, GeordiPermission permission) {
        if (principal == null || permission == null || !principal.permissions().contains(permission)) {
            throw new PermissionDeniedException();
        }
    }
}
