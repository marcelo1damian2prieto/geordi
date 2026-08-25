package io.geordi.alerts;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;
import java.util.function.BooleanSupplier;

public final class AlertsPlatformModule implements PlatformModule {

    private final BooleanSupplier capabilityAvailable;

    public AlertsPlatformModule(BooleanSupplier capabilityAvailable) {
        this.capabilityAvailable = Objects.requireNonNull(capabilityAvailable, "availability must not be null");
    }

    @Override
    public String id() {
        return "alerts";
    }

    @Override
    public String name() {
        return "Alert Evaluation";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return () -> capabilityAvailable.getAsBoolean() ? ModuleStatus.UP : ModuleStatus.DOWN;
    }
}
