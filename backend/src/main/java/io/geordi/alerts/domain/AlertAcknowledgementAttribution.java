package io.geordi.alerts.domain;

import java.net.URI;
import java.util.Objects;

/** Alerts-owned historical attribution; deliberately independent of security adapters and core. */
public record AlertAcknowledgementAttribution(Provenance provenance, Identity identity, String displayName) {
    public enum Provenance { LEGACY_CALLER_ASSERTED, AUTHENTICATED_PRINCIPAL }

    public AlertAcknowledgementAttribution {
        Objects.requireNonNull(provenance, "attribution provenance required");
        if (provenance == Provenance.LEGACY_CALLER_ASSERTED) {
            if (identity != null || displayName != null) {
                throw new IllegalArgumentException("legacy attribution cannot contain identity");
            }
        } else {
            Objects.requireNonNull(identity, "authenticated attribution requires identity");
            if (displayName != null && (displayName.isEmpty()
                    || displayName.codePointCount(0, displayName.length()) > 128
                    || displayName.codePoints().anyMatch(value -> Character.isISOControl(value)
                            || value >= Character.MIN_SURROGATE && value <= Character.MAX_SURROGATE))) {
                throw new IllegalArgumentException("invalid attribution snapshot");
            }
        }
    }

    public static AlertAcknowledgementAttribution legacy() {
        return new AlertAcknowledgementAttribution(Provenance.LEGACY_CALLER_ASSERTED, null, null);
    }

    public static AlertAcknowledgementAttribution authenticated(String issuer, String subject, String displayName) {
        return new AlertAcknowledgementAttribution(Provenance.AUTHENTICATED_PRINCIPAL,
                new Identity(issuer, subject), displayName);
    }

    public String actor() {
        if (provenance != Provenance.AUTHENTICATED_PRINCIPAL) {
            throw new IllegalStateException("legacy actor belongs to the original acknowledgement");
        }
        return displayName == null ? "Authenticated principal" : displayName;
    }

    public record Identity(String issuer, String subject) {
        public Identity {
            if (issuer == null || issuer.isEmpty() || issuer.length() > 2048
                    || !issuer.chars().allMatch(value -> value >= 33 && value <= 126)) {
                throw new IllegalArgumentException("invalid attribution issuer");
            }
            URI uri;
            try {
                uri = URI.create(issuer);
            } catch (IllegalArgumentException exception) {
                throw new IllegalArgumentException("invalid attribution issuer");
            }
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                    || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) {
                throw new IllegalArgumentException("invalid attribution issuer");
            }
            if (subject == null || subject.isBlank() || subject.length() > 255
                    || !subject.chars().allMatch(value -> value >= 32 && value <= 126)) {
                throw new IllegalArgumentException("invalid attribution subject");
            }
        }
    }
}
