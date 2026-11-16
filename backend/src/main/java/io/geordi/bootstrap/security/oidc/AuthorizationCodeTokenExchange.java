package io.geordi.bootstrap.security.oidc;

import java.net.URI;

@FunctionalInterface
public interface AuthorizationCodeTokenExchange {
    String exchange(String code, String codeVerifier, URI redirectUri);
}
