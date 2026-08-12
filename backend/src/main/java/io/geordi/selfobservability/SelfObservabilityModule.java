package io.geordi.selfobservability;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;

public final class SelfObservabilityModule implements PlatformModule {

    private static final ModuleHealthCheck HEALTH_CHECK = () -> ModuleStatus.UP;

    @Override
    public String id() {
        return "self-observability";
    }

    @Override
    public String name() {
        return "Self Observability";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return HEALTH_CHECK;
    }
}
