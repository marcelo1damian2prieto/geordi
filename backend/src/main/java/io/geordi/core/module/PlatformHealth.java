package io.geordi.core.module;

import java.util.List;

public record PlatformHealth(ModuleStatus status, List<ModuleSnapshot> modules) {

    public PlatformHealth {
        modules = List.copyOf(modules);
    }
}
