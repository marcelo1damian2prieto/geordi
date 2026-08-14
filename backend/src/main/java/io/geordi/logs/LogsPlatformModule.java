package io.geordi.logs;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;

public final class LogsPlatformModule implements PlatformModule {

    private final ModuleHealthCheck healthCheck;

    public LogsPlatformModule(ModuleHealthCheck healthCheck) {
        this.healthCheck = Objects.requireNonNull(healthCheck, "health check must not be null");
    }

    @Override
    public String id() {
        return "logs";
    }

    @Override
    public String name() {
        return "Logs";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return healthCheck;
    }
}
