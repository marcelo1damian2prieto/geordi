package io.geordi.bootstrap.security.jwt;

import io.geordi.core.application.security.AuthenticatedPrincipal;

@FunctionalInterface
public interface BearerTokenAuthenticator {
    AuthenticatedPrincipal authenticate(String token);
}
