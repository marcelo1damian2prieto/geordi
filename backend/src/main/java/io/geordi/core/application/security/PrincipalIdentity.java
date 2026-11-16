package io.geordi.core.application.security;

import java.net.URI;

/** Exact external identity. Display metadata and grants never participate in equality. */
public record PrincipalIdentity(String issuer, String subject) {
    public PrincipalIdentity {
        if (issuer == null || issuer.isEmpty() || issuer.length() > 2048
                || !issuer.chars().allMatch(value -> value >= 33 && value <= 126)) {
            throw new IllegalArgumentException("invalid identity issuer");
        }
        URI uri;
        try {
            uri = URI.create(issuer);
        } catch (IllegalArgumentException exception) {
            throw new IllegalArgumentException("invalid identity issuer");
        }
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) {
            throw new IllegalArgumentException("invalid identity issuer");
        }
        if (subject == null || subject.isBlank() || subject.length() > 255
                || !subject.chars().allMatch(value -> value >= 32 && value <= 126)) {
            throw new IllegalArgumentException("invalid identity subject");
        }
    }

    @Override
    public String toString() {
        return "PrincipalIdentity[redacted]";
    }
}
