package io.geordi.alerts.application.port.out;

@FunctionalInterface
public interface SloReferencePort {

    boolean exists(String sloId);
}
