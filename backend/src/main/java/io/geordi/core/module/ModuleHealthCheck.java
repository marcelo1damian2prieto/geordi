package io.geordi.core.module;

@FunctionalInterface
public interface ModuleHealthCheck {

    ModuleStatus check();
}
