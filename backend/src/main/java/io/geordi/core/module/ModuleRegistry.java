package io.geordi.core.module;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.NavigableMap;
import java.util.Objects;
import java.util.TreeMap;

public final class ModuleRegistry {

    private static final String CORE_MODULE_ID = "core";

    private final NavigableMap<String, PlatformModule> modulesById;
    private final ModuleHealthFailureObserver failureObserver;

    public ModuleRegistry(Collection<? extends PlatformModule> modules) {
        this(modules, ModuleHealthFailureObserver.NO_OP);
    }

    public ModuleRegistry(
            Collection<? extends PlatformModule> modules,
            ModuleHealthFailureObserver failureObserver) {
        Objects.requireNonNull(modules, "modules must not be null");
        this.failureObserver = Objects.requireNonNull(failureObserver, "failure observer must not be null");
        TreeMap<String, PlatformModule> registeredModules = new TreeMap<>();
        for (PlatformModule module : modules) {
            validateMetadata(module);
            PlatformModule previous = registeredModules.putIfAbsent(module.id(), module);
            if (previous != null) {
                throw new IllegalArgumentException("Duplicate platform module id: " + module.id());
            }
        }
        validateCore(registeredModules);
        modulesById = Collections.unmodifiableNavigableMap(registeredModules);
    }

    public List<ModuleSnapshot> modules() {
        List<ModuleSnapshot> snapshots = new ArrayList<>(modulesById.size());
        modulesById.values().forEach(module -> snapshots.add(inspect(module)));
        return List.copyOf(snapshots);
    }

    public PlatformHealth health() {
        List<ModuleSnapshot> snapshots = modules();
        ModuleStatus status = ModuleStatus.UP;
        for (ModuleSnapshot snapshot : snapshots) {
            if (snapshot.status() == ModuleStatus.DOWN) {
                status = ModuleStatus.DOWN;
                break;
            }
            if (snapshot.status() == ModuleStatus.UNKNOWN) {
                status = ModuleStatus.UNKNOWN;
            }
        }
        return new PlatformHealth(status, snapshots);
    }

    private ModuleSnapshot inspect(PlatformModule module) {
        if (!module.enabled()) {
            return new ModuleSnapshot(module.id(), module.name(), false, ModuleStatus.DISABLED);
        }

        ModuleStatus status;
        try {
            status = module.healthCheck().check();
            if (status == null || status == ModuleStatus.DISABLED) {
                status = ModuleStatus.DOWN;
            }
        } catch (RuntimeException exception) {
            notifyFailure(module.id(), exception);
            status = ModuleStatus.DOWN;
        }
        return new ModuleSnapshot(module.id(), module.name(), true, status);
    }

    @SuppressWarnings("PMD.EmptyCatchBlock")
    private void notifyFailure(String moduleId, RuntimeException exception) {
        try {
            failureObserver.onFailure(new ModuleHealthFailure(moduleId, exception));
        } catch (RuntimeException observerException) {
            // Health reporting must remain available even if its operational observer fails.
        }
    }

    private static void validateMetadata(PlatformModule module) {
        Objects.requireNonNull(module, "platform module must not be null");
        requireText(module.id(), "module id");
        requireText(module.name(), "module name");
        Objects.requireNonNull(module.healthCheck(), "module health check must not be null");
    }

    private static void requireText(String value, String description) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
    }

    private static void validateCore(NavigableMap<String, PlatformModule> registeredModules) {
        PlatformModule core = registeredModules.get(CORE_MODULE_ID);
        if (core == null || !core.enabled()) {
            throw new IllegalStateException("The core platform module is mandatory and must be enabled");
        }
    }
}
