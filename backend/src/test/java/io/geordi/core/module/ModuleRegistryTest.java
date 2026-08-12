package io.geordi.core.module;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class ModuleRegistryTest {

    @Test
    void exposesInventoryInDeterministicIdOrderWithoutEvaluatingHealth() {
        AtomicInteger checks = new AtomicInteger();
        ModuleRegistry registry = new ModuleRegistry(List.of(
                module("self-observability", "Self Observability", () -> {
                    checks.incrementAndGet();
                    return ModuleStatus.UP;
                }),
                module("core", "Core", () -> {
                    checks.incrementAndGet();
                    return ModuleStatus.UP;
                })), Map.of());

        assertThat(registry.modules())
                .containsExactly(
                        new ModuleInventory("core", "Core", true),
                        new ModuleInventory("self-observability", "Self Observability", true));
        assertThat(checks).hasValue(0);
    }

    @Test
    void appliesGenericActivationAndDefaultsUnconfiguredModulesToEnabled() {
        ModuleRegistry registry = new ModuleRegistry(List.of(
                module("core", "Core", ModuleStatus.UP),
                module("future-module", "Future Module", ModuleStatus.UP)),
                Map.of("future-module", false));

        assertThat(registry.modules())
                .containsExactly(
                        new ModuleInventory("core", "Core", true),
                        new ModuleInventory("future-module", "Future Module", false));
    }

    @Test
    void rejectsDuplicateIdsAndInvalidInventoryMetadata() {
        PlatformModule core = module("core", "Core", ModuleStatus.UP);

        assertThatThrownBy(() -> new ModuleRegistry(List.of(core, module("core", "Other Core", ModuleStatus.UP)), Map.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("core");
        assertThatThrownBy(() -> new ModuleRegistry(List.of(core, module(" ", "Blank Id", ModuleStatus.UP)), Map.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("id");
        assertThatThrownBy(() -> new ModuleRegistry(List.of(core, module("blank-name", " ", ModuleStatus.UP)), Map.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("name");
    }

    @Test
    void rejectsUnknownConfigurationAndRequiresEnabledCore() {
        PlatformModule core = module("core", "Core", ModuleStatus.UP);

        assertThatThrownBy(() -> new ModuleRegistry(List.of(core), Map.of("typo", true)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("typo");
        assertThatThrownBy(() -> new ModuleRegistry(
                        List.of(module("future-module", "Future Module", ModuleStatus.UP)), Map.of()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("core");
        assertThatThrownBy(() -> new ModuleRegistry(List.of(core), Map.of("core", false)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("core");
    }

    private static PlatformModule module(String id, String name, ModuleStatus status) {
        return module(id, name, status == null ? null : () -> status);
    }

    private static PlatformModule module(String id, String name, ModuleHealthCheck healthCheck) {
        return new StubModule(id, name, healthCheck);
    }

    private record StubModule(String id, String name, ModuleHealthCheck healthCheck) implements PlatformModule {
    }
}
