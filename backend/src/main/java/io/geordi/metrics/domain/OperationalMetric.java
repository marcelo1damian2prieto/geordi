package io.geordi.metrics.domain;

public enum OperationalMetric {
    JVM_MEMORY_USED("By"),
    JVM_CPU_UTILIZATION("1"),
    JVM_THREAD_COUNT("{thread}"),
    JVM_GC_DURATION("s"),
    HTTP_REQUEST_RATE("{request}/s"),
    HTTP_REQUEST_COUNT("{request}"),
    HTTP_REQUEST_LATENCY_P95("s"),
    HTTP_ERROR_RATE("1"),
    HTTP_ERROR_COUNT("{request}");

    private final String unit;

    OperationalMetric(String unit) {
        this.unit = unit;
    }

    public String unit() {
        return unit;
    }
}
