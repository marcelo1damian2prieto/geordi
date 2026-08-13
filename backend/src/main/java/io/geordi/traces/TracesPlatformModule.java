package io.geordi.traces;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;

public final class TracesPlatformModule implements PlatformModule {

    private final ModuleHealthCheck healthCheck;

    public TracesPlatformModule(ModuleHealthCheck healthCheck) {
        this.healthCheck = Objects.requireNonNull(healthCheck, "health check must not be null");
    }

    @Override
    public String id() {
        return "traces";
    }

    @Override
    public String name() {
        return "Traces";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return healthCheck;
    }
}
