package io.geordi.core.application.security;

public final class PermissionDeniedException extends RuntimeException {
    public PermissionDeniedException() {
        super("Permission denied");
    }
}
