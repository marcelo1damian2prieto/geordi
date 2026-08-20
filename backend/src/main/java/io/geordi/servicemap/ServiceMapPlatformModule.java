package io.geordi.servicemap;

import io.geordi.core.module.ModuleHealthCheck;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import java.util.Objects;
import java.util.function.BooleanSupplier;

public final class ServiceMapPlatformModule implements PlatformModule {

    private final BooleanSupplier evidenceAvailable;

    public ServiceMapPlatformModule(BooleanSupplier evidenceAvailable) {
        this.evidenceAvailable = Objects.requireNonNull(evidenceAvailable, "evidence availability must not be null");
    }

    @Override
    public String id() {
        return "service-map";
    }

    @Override
    public String name() {
        return "Service Map";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return () -> evidenceAvailable.getAsBoolean() ? ModuleStatus.UP : ModuleStatus.DOWN;
    }
}
