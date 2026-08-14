package io.geordi.logs.domain;

import java.util.Locale;
import java.util.regex.Pattern;

public record TraceId(String value) {

    private static final Pattern VALID = Pattern.compile("[0-9a-fA-F]{32}");
    private static final String ZERO = "0".repeat(32);

    public TraceId {
        if (value == null || !VALID.matcher(value).matches() || ZERO.equals(value)) {
            throw new IllegalArgumentException("trace id must be a non-zero 16-byte hexadecimal value");
        }
        value = value.toLowerCase(Locale.ROOT);
    }
}
