package io.geordi.alerts.domain;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Objects;

/**
 * Stable opaque identity for one canonical lifecycle transition.
 */
public record AlertTransitionId(String value) {

    private static final int SHA_256_HEX_LENGTH = 64;

    public AlertTransitionId {
        if (Objects.requireNonNull(value, "alert transition id must not be null").length() != SHA_256_HEX_LENGTH
                || !value.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("alert transition id must be a lowercase SHA-256 hexadecimal value");
        }
    }

    public static AlertTransitionId from(AlertTransition transition) {
        Objects.requireNonNull(transition, "alert transition must not be null");
        String identity = transition.policyId() + "\n" + transition.type().name() + "\n" + transition.occurredAt();
        try {
            return new AlertTransitionId(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(identity.getBytes(StandardCharsets.UTF_8))));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available", exception);
        }
    }
}
