package io.geordi.core.module;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

class PlatformHealthServiceTest {

    @Test
    void evaluatesEveryEnabledModuleExactlyOncePerSnapshotAndSkipsDisabledModules() {
        AtomicInteger coreChecks = new AtomicInteger();
        AtomicInteger enabledChecks = new AtomicInteger();
        AtomicInteger disabledChecks = new AtomicInteger();
        ModuleRegistry registry = registry(List.of(
                module("core", "Core", counting(coreChecks, ModuleStatus.UP)),
                module("enabled", "Enabled", counting(enabledChecks, ModuleStatus.UP)),
                module("disabled", "Disabled", counting(disabledChecks, ModuleStatus.DOWN))),
                Map.of("disabled", false));
        PlatformHealthService service = new PlatformHealthService(registry);

        PlatformHealth first = service.health();

        assertThat(first.status()).isEqualTo(ModuleStatus.UP);
        assertThat(first.modules()).containsExactly(
                new ModuleSnapshot("core", "Core", true, ModuleStatus.UP),
                new ModuleSnapshot("disabled", "Disabled", false, ModuleStatus.DISABLED),
                new ModuleSnapshot("enabled", "Enabled", true, ModuleStatus.UP));
        assertThat(coreChecks).hasValue(1);
        assertThat(enabledChecks).hasValue(1);
        assertThat(disabledChecks).hasValue(0);

        service.health();
        assertThat(coreChecks).hasValue(2);
        assertThat(enabledChecks).hasValue(2);
        assertThat(disabledChecks).hasValue(0);
    }

    @Test
    void normalizesNullAndDisabledResultsToDownAndUsesDownUnknownUpPrecedence() {
        assertThat(healthWith(ModuleStatus.UP, ModuleStatus.UP).status()).isEqualTo(ModuleStatus.UP);
        assertThat(healthWith(ModuleStatus.UP, ModuleStatus.UNKNOWN).status()).isEqualTo(ModuleStatus.UNKNOWN);
        assertThat(healthWith(ModuleStatus.UNKNOWN, ModuleStatus.DOWN).status()).isEqualTo(ModuleStatus.DOWN);
        assertThat(healthWith(ModuleStatus.UP, null).status()).isEqualTo(ModuleStatus.DOWN);
        assertThat(healthWith(ModuleStatus.UP, ModuleStatus.DISABLED).status()).isEqualTo(ModuleStatus.DOWN);
    }

    @Test
    void isolatesCheckAndObserverExceptionsAndContinuesTheSnapshot() {
        AtomicInteger laterChecks = new AtomicInteger();
        AtomicReference<ModuleHealthFailure> observed = new AtomicReference<>();
        ModuleRegistry registry = registry(List.of(
                module("core", "Core", ModuleStatus.UP),
                module("failing", "Failing", () -> {
                    throw new IllegalStateException("secret failure details");
                }),
                module("later", "Later", counting(laterChecks, ModuleStatus.UNKNOWN))), Map.of());
        PlatformHealthService service = new PlatformHealthService(registry, failure -> {
            observed.set(failure);
            throw new IllegalStateException("observer failure");
        });

        PlatformHealth health = service.health();

        assertThat(health.status()).isEqualTo(ModuleStatus.DOWN);
        assertThat(health.modules()).extracting(ModuleSnapshot::status)
                .containsExactly(ModuleStatus.UP, ModuleStatus.DOWN, ModuleStatus.UNKNOWN);
        assertThat(laterChecks).hasValue(1);
        assertThat(observed.get().moduleId()).isEqualTo("failing");
        assertThat(observed.get().cause()).hasMessage("secret failure details");
        assertThat(health.toString()).doesNotContain("secret failure details");
    }

    @Test
    void isolatesHealthCheckAccessorExceptionsWithoutBreakingInventoryOrLaterChecks() {
        AtomicInteger laterChecks = new AtomicInteger();
        PlatformModule failingAccessor = new PlatformModule() {
            @Override
            public String id() {
                return "failing-accessor";
            }

            @Override
            public String name() {
                return "Failing Accessor";
            }

            @Override
            public ModuleHealthCheck healthCheck() {
                throw new IllegalStateException("accessor failure");
            }
        };
        ModuleRegistry registry = registry(List.of(
                module("core", "Core", ModuleStatus.UP),
                failingAccessor,
                module("later", "Later", counting(laterChecks, ModuleStatus.UP))), Map.of());

        assertThat(registry.modules()).extracting(ModuleInventory::id)
                .containsExactly("core", "failing-accessor", "later");

        PlatformHealth health = new PlatformHealthService(registry).health();

        assertThat(health.status()).isEqualTo(ModuleStatus.DOWN);
        assertThat(health.modules()).extracting(ModuleSnapshot::status)
                .containsExactly(ModuleStatus.UP, ModuleStatus.DOWN, ModuleStatus.UP);
        assertThat(laterChecks).hasValue(1);
    }

    private static PlatformHealth healthWith(ModuleStatus core, ModuleStatus other) {
        return new PlatformHealthService(registry(List.of(
                module("core", "Core", () -> core),
                module("other", "Other", () -> other)), Map.of())).health();
    }

    private static ModuleRegistry registry(List<PlatformModule> modules, Map<String, Boolean> activation) {
        return new ModuleRegistry(modules, activation);
    }

    private static ModuleHealthCheck counting(AtomicInteger count, ModuleStatus status) {
        return () -> {
            count.incrementAndGet();
            return status;
        };
    }

    private static PlatformModule module(String id, String name, ModuleStatus status) {
        return module(id, name, () -> status);
    }

    private static PlatformModule module(String id, String name, ModuleHealthCheck healthCheck) {
        return new StubModule(id, name, healthCheck);
    }

    private record StubModule(String id, String name, ModuleHealthCheck healthCheck) implements PlatformModule {
    }
}
