package io.geordi.core.module;

public final class CorePlatformModule implements PlatformModule {

    private static final ModuleHealthCheck HEALTH_CHECK = () -> ModuleStatus.UP;

    @Override
    public String id() {
        return "core";
    }

    @Override
    public String name() {
        return "Core";
    }

    @Override
    public ModuleHealthCheck healthCheck() {
        return HEALTH_CHECK;
    }
}
