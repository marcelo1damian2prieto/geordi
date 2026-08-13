package io.geordi.metrics;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;

public final class MetricsPlatformModule implements PlatformModule {

    private final ModuleHealthCheck healthCheck;

    public MetricsPlatformModule(ModuleHealthCheck healthCheck) {
        this.healthCheck = Objects.requireNonNull(healthCheck, "health check must not be null");
    }

    @Override
    public String id() {
        return "metrics";
    }

    @Override
    public String name() {
        return "Metrics";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return healthCheck;
    }
}
