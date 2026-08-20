package io.geordi.servicemap.domain;

import java.util.regex.Pattern;

public record TraceId(String value) implements Comparable<TraceId> {

    private static final Pattern VALID = Pattern.compile("[0-9a-f]{32}");

    public TraceId {
        if (value == null || !VALID.matcher(value).matches()) {
            throw new IllegalArgumentException("trace id must be 32 lowercase hexadecimal characters");
        }
    }

    @Override
    public int compareTo(TraceId other) {
        return value.compareTo(other.value);
    }
}
