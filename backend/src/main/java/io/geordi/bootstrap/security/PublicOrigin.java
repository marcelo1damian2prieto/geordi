package io.geordi.bootstrap.security;

import io.geordi.core.application.security.PrincipalIdentity;
import java.net.URI;

/** All redirects and origin checks use this deployment value, never request headers. */
public record PublicOrigin(String value) {
    public PublicOrigin {
        new PrincipalIdentity(value, "configuration");
        if (!URI.create(value).getRawPath().isEmpty()) {
            throw new IllegalArgumentException("public base URL must be an HTTPS origin without a path");
        }
    }

    public String callback() {
        return value + "/login/oauth2/code/geordi";
    }

    public void requireMatching(String origin) {
        if (origin != null && !value.equals(origin)) {
            throw new SecurityFailure(SecurityFailure.Kind.ORIGIN);
        }
    }
}
