package io.geordi.metrics.application.port.out;

@FunctionalInterface
public interface MetricsBackendProbe {

    boolean isQueryable();
}
