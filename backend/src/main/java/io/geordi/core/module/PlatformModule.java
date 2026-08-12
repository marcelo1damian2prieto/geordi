package io.geordi.core.module;

public interface PlatformModule {

    String id();

    String name();

    ModuleHealthCheck healthCheck();
}
