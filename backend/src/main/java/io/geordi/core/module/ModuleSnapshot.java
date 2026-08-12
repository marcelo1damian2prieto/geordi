package io.geordi.core.module;

public record ModuleSnapshot(String id, String name, boolean enabled, ModuleStatus status) {
}
