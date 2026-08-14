package io.geordi.logs.application.port.out;

@FunctionalInterface
public interface LogsBackendProbe {

    boolean isQueryable();
}
