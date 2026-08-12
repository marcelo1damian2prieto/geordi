package io.geordi.core.module;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public final class PlatformHealthService {

    private final ModuleRegistry registry;
    private final ModuleHealthFailureObserver failureObserver;

    public PlatformHealthService(ModuleRegistry registry) {
        this(registry, ModuleHealthFailureObserver.NO_OP);
    }

    public PlatformHealthService(
            ModuleRegistry registry,
            ModuleHealthFailureObserver failureObserver) {
        this.registry = Objects.requireNonNull(registry, "module registry must not be null");
        this.failureObserver = Objects.requireNonNull(failureObserver, "failure observer must not be null");
    }

    public PlatformHealth health() {
        List<ModuleSnapshot> snapshots = new ArrayList<>();
        ModuleStatus platformStatus = ModuleStatus.UP;
        for (ModuleRegistry.RegisteredModule registered : registry.registrations()) {
            ModuleSnapshot snapshot = inspect(registered);
            snapshots.add(snapshot);
            platformStatus = aggregate(platformStatus, snapshot);
        }
        return new PlatformHealth(platformStatus, snapshots);
    }

    private ModuleSnapshot inspect(ModuleRegistry.RegisteredModule registered) {
        PlatformModule module = registered.module();
        if (!registered.enabled()) {
            return new ModuleSnapshot(module.id(), module.name(), false, ModuleStatus.DISABLED);
        }

        ModuleStatus status;
        try {
            status = normalize(module.healthCheck().check());
        } catch (RuntimeException exception) {
            notifyFailure(module.id(), exception);
            status = ModuleStatus.DOWN;
        }
        return new ModuleSnapshot(module.id(), module.name(), true, status);
    }

    private static ModuleStatus normalize(ModuleStatus status) {
        return status == null || status == ModuleStatus.DISABLED ? ModuleStatus.DOWN : status;
    }

    private static ModuleStatus aggregate(ModuleStatus current, ModuleSnapshot snapshot) {
        if (!snapshot.enabled() || current == ModuleStatus.DOWN) {
            return current;
        }
        if (snapshot.status() == ModuleStatus.DOWN) {
            return ModuleStatus.DOWN;
        }
        if (snapshot.status() == ModuleStatus.UNKNOWN) {
            return ModuleStatus.UNKNOWN;
        }
        return current;
    }

    @SuppressWarnings("PMD.EmptyCatchBlock")
    private void notifyFailure(String moduleId, RuntimeException exception) {
        try {
            failureObserver.onFailure(new ModuleHealthFailure(moduleId, exception));
        } catch (RuntimeException observerException) {
            // Health reporting must remain available even if its operational observer fails.
        }
    }
}
