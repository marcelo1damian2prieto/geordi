package io.geordi.slos;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;
import java.util.function.BooleanSupplier;

public final class SlosPlatformModule implements PlatformModule {

    private final BooleanSupplier capabilityAvailable;

    public SlosPlatformModule(BooleanSupplier capabilityAvailable) {
        this.capabilityAvailable = Objects.requireNonNull(capabilityAvailable, "availability must not be null");
    }

    @Override
    public String id() {
        return "slos";
    }

    @Override
    public String name() {
        return "SLOs";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return () -> capabilityAvailable.getAsBoolean() ? ModuleStatus.UP : ModuleStatus.DOWN;
    }
}
