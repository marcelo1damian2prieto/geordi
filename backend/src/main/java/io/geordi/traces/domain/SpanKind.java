package io.geordi.traces.domain;

public enum SpanKind {
    UNSPECIFIED,
    INTERNAL,
    SERVER,
    CLIENT,
    PRODUCER,
    CONSUMER
}
