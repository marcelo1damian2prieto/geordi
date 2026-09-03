package io.geordi.alerts.domain;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Objects;

/**
 * Stable opaque identity for one durable alert episode.
 */
public record AlertEpisodeId(String value) {

    private static final int SHA_256_HEX_LENGTH = 64;

    public AlertEpisodeId {
        if (Objects.requireNonNull(value, "alert episode id must not be null").length() != SHA_256_HEX_LENGTH
                || !value.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("alert episode id must be a lowercase SHA-256 hexadecimal value");
        }
    }

    public static AlertEpisodeId opened(String policyId, Instant startedAt) {
        requirePolicyId(policyId);
        Objects.requireNonNull(startedAt, "alert episode start time must not be null");
        return new AlertEpisodeId(hash(policyId + "\n" + startedAt));
    }

    public static AlertEpisodeId legacyResolved(String policyId, Instant resolvedAt) {
        requirePolicyId(policyId);
        Objects.requireNonNull(resolvedAt, "legacy alert episode resolution time must not be null");
        return new AlertEpisodeId(hash(policyId + "\nPRE_M14_UNKNOWN_START\n" + resolvedAt));
    }

    private static String hash(String identity) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(identity.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available", exception);
        }
    }

    private static void requirePolicyId(String policyId) {
        if (Objects.requireNonNull(policyId, "alert policy id must not be null").isBlank()) {
            throw new IllegalArgumentException("alert policy id must not be blank");
        }
    }
}
