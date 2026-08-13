package io.geordi.traces.application.port.out;

@FunctionalInterface
public interface TraceBackendProbe {

    boolean isQueryable();
}
