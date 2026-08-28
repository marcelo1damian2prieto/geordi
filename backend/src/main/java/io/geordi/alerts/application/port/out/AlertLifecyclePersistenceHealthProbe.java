package io.geordi.alerts.application.port.out;

@FunctionalInterface
public interface AlertLifecyclePersistenceHealthProbe {

    boolean isAvailable();
}
