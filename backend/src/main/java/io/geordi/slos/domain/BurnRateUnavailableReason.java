package io.geordi.slos.domain;

public enum BurnRateUnavailableReason {
    DISABLED,
    NO_TRAFFIC,
    MISSING_REQUEST_COUNT,
    MISSING_ERROR_COUNT,
    INVALID_TELEMETRY,
    METRICS_UNAVAILABLE,
    ZERO_ALLOWED_BAD_RATIO
}
