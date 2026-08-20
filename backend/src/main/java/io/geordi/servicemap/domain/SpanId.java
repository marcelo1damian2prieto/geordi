package io.geordi.servicemap.domain;

import java.util.regex.Pattern;

public record SpanId(String value) {

    private static final Pattern VALID = Pattern.compile("[0-9a-f]{16}");

    public SpanId {
        if (value == null || !VALID.matcher(value).matches()) {
            throw new IllegalArgumentException("span id must be 16 lowercase hexadecimal characters");
        }
    }
}
