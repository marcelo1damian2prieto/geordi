package io.geordi.core.module;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class ModuleRegistryTest {

    @Test
    void rejectsDuplicateModuleIds() {
        PlatformModule firstCore = module("core", "Core", true, ModuleStatus.UP);
        PlatformModule duplicateCore = module("core", "Other Core", true, ModuleStatus.UP);

        assertThatThrownBy(() -> new ModuleRegistry(List.of(firstCore, duplicateCore)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("core");
    }

    @Test
    void reportsModulesInDeterministicIdOrder() {
        ModuleRegistry registry = new ModuleRegistry(List.of(
                module("self-observability", "Self Observability", true, ModuleStatus.UP),
                module("core", "Core", true, ModuleStatus.UP)));

        assertThat(registry.modules()).extracting(ModuleSnapshot::id)
                .containsExactly("core", "self-observability");
    }

    @Test
    void leavesDisabledModulesVisibleWithoutCheckingTheirHealth() {
        AtomicInteger healthChecks = new AtomicInteger();
        PlatformModule disabled = new StubModule(
                "self-observability", "Self Observability", false, () -> {
                    healthChecks.incrementAndGet();
                    throw new IllegalStateException("must not run");
                });
        ModuleRegistry registry = new ModuleRegistry(List.of(
                module("core", "Core", true, ModuleStatus.UP), disabled));

        assertThat(registry.modules())
                .filteredOn(snapshot -> snapshot.id().equals("self-observability"))
                .singleElement()
                .extracting(ModuleSnapshot::status)
                .isEqualTo(ModuleStatus.DISABLED);
        assertThat(registry.health().status()).isEqualTo(ModuleStatus.UP);
        assertThat(healthChecks).hasValue(0);
    }

    @Test
    void aggregatesDownBeforeUnknownAndOtherwiseUp() {
        assertThat(registryWith(ModuleStatus.UP, ModuleStatus.UP).health().status())
                .isEqualTo(ModuleStatus.UP);
        assertThat(registryWith(ModuleStatus.UP, ModuleStatus.UNKNOWN).health().status())
                .isEqualTo(ModuleStatus.UNKNOWN);
        assertThat(registryWith(ModuleStatus.UNKNOWN, ModuleStatus.DOWN).health().status())
                .isEqualTo(ModuleStatus.DOWN);
    }

    @Test
    void isolatesHealthCheckExceptionsAndContinuesCheckingOtherModules() {
        AtomicInteger secondModuleChecks = new AtomicInteger();
        AtomicReference<ModuleHealthFailure> observedFailure = new AtomicReference<>();
        PlatformModule failingModule = new StubModule(
                "a-failing", "Failing", true, () -> {
                    throw new IllegalStateException("secret failure details");
                });
        PlatformModule checkedAfterFailure = new StubModule(
                "self-observability", "Self Observability", true, () -> {
                    secondModuleChecks.incrementAndGet();
                    return ModuleStatus.UP;
                });
        ModuleRegistry registry = new ModuleRegistry(
                List.of(module("core", "Core", true, ModuleStatus.UP), failingModule, checkedAfterFailure),
                observedFailure::set);

        PlatformHealth health = registry.health();

        assertThat(health.status()).isEqualTo(ModuleStatus.DOWN);
        assertThat(health.modules()).filteredOn(module -> module.id().equals("a-failing"))
                .singleElement().extracting(ModuleSnapshot::status).isEqualTo(ModuleStatus.DOWN);
        assertThat(secondModuleChecks).hasValue(1);
        assertThat(observedFailure.get().moduleId()).isEqualTo("a-failing");
        assertThat(observedFailure.get().cause())
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("secret failure details");
        assertThat(health.toString()).doesNotContain("secret failure details");
    }

    @Test
    void requiresAnEnabledCoreModule() {
        assertThatThrownBy(() -> new ModuleRegistry(List.of(
                        module("self-observability", "Self Observability", true, ModuleStatus.UP))))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("core");

        assertThatThrownBy(() -> new ModuleRegistry(List.of(
                        module("core", "Core", false, ModuleStatus.UP))))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("core");
    }

    @Test
    void isolatesFailureObserverExceptionsFromHealthReporting() {
        PlatformModule failingModule = new StubModule(
                "failing", "Failing", true, () -> {
                    throw new IllegalStateException("health failure");
                });
        ModuleRegistry registry = new ModuleRegistry(
                List.of(module("core", "Core", true, ModuleStatus.UP), failingModule),
                failure -> {
                    throw new IllegalStateException("observer failure");
                });

        assertThat(registry.health().status()).isEqualTo(ModuleStatus.DOWN);
    }

    private static ModuleRegistry registryWith(ModuleStatus coreStatus, ModuleStatus otherStatus) {
        return new ModuleRegistry(List.of(
                module("core", "Core", true, coreStatus),
                module("self-observability", "Self Observability", true, otherStatus)));
    }

    private static PlatformModule module(String id, String name, boolean enabled, ModuleStatus status) {
        return new StubModule(id, name, enabled, () -> status);
    }

    private record StubModule(String id, String name, boolean enabled, ModuleHealthCheck healthCheck)
            implements PlatformModule {
    }
}
