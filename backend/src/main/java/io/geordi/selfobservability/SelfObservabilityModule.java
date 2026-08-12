package io.geordi.selfobservability;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;

public final class SelfObservabilityModule implements PlatformModule {

    private static final ModuleHealthCheck HEALTH_CHECK = () -> ModuleStatus.UP;

    private final boolean enabled;

    public SelfObservabilityModule(boolean enabled) {
        this.enabled = enabled;
    }

    @Override
    public String id() {
        return "self-observability";
    }

    @Override
    public String name() {
        return "Self Observability";
    }

    @Override
    public boolean enabled() {
        return enabled;
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return HEALTH_CHECK;
    }
}
