package io.geordi.core.module;

public interface PlatformModule {

    String id();

    String name();

    boolean enabled();

    ModuleHealthCheck healthCheck();
}
