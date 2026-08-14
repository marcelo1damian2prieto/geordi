package io.geordi.logs.domain;

import java.util.Locale;
import java.util.regex.Pattern;

public record SpanId(String value) {

    private static final Pattern VALID = Pattern.compile("[0-9a-fA-F]{16}");
    private static final String ZERO = "0".repeat(16);

    public SpanId {
        if (value == null || !VALID.matcher(value).matches() || ZERO.equals(value)) {
            throw new IllegalArgumentException("span id must be a non-zero 8-byte hexadecimal value");
        }
        value = value.toLowerCase(Locale.ROOT);
    }
}
