package io.geordi.alerts.domain;

public enum AlertUnavailableReason {
    DISABLED,
    NO_TRAFFIC,
    MISSING_REQUEST_COUNT,
    MISSING_ERROR_COUNT,
    INVALID_TELEMETRY,
    METRICS_UNAVAILABLE,
    ZERO_ALLOWED_BAD_RATIO
}
