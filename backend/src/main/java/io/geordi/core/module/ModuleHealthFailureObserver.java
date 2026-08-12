package io.geordi.core.module;

@FunctionalInterface
public interface ModuleHealthFailureObserver {

    ModuleHealthFailureObserver NO_OP = failure -> { };

    void onFailure(ModuleHealthFailure failure);
}
