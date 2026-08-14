package io.geordi.logs.domain;

import java.util.Locale;

public enum LogSeverity {
    UNSPECIFIED,
    TRACE,
    DEBUG,
    INFO,
    WARN,
    ERROR,
    FATAL;

    public static LogSeverity from(Integer number, String text) {
        if (number != null) {
            if (number < 0 || number > 24) {
                throw new IllegalArgumentException("severity number must be between zero and 24");
            }
            if (number == 0) {
                return UNSPECIFIED;
            }
            return values()[(number - 1) / 4 + 1];
        }
        if (text == null || text.isBlank()) {
            return UNSPECIFIED;
        }
        String normalized = text.trim().toUpperCase(Locale.ROOT);
        for (LogSeverity severity : values()) {
            if (normalized.startsWith(severity.name())) {
                return severity;
            }
        }
        return UNSPECIFIED;
    }
}
