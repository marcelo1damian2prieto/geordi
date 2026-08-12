package io.geordi.core.module;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.NavigableMap;
import java.util.Objects;
import java.util.TreeMap;

public final class ModuleRegistry {

    private static final String CORE_MODULE_ID = "core";

    private final NavigableMap<String, RegisteredModule> modulesById;

    public ModuleRegistry(Collection<? extends PlatformModule> modules) {
        this(modules, Map.of());
    }

    public ModuleRegistry(
            Collection<? extends PlatformModule> modules,
            Map<String, Boolean> configuredActivation) {
        Objects.requireNonNull(modules, "modules must not be null");
        Objects.requireNonNull(configuredActivation, "configured activation must not be null");

        TreeMap<String, PlatformModule> discoveredModules = discover(modules);
        validateConfiguredIds(discoveredModules, configuredActivation);
        validateCore(discoveredModules, configuredActivation);

        TreeMap<String, RegisteredModule> registeredModules = new TreeMap<>();
        discoveredModules.forEach((id, module) -> registeredModules.put(
                id, new RegisteredModule(module, configuredActivation.getOrDefault(id, true))));
        modulesById = Collections.unmodifiableNavigableMap(registeredModules);
    }

    public List<ModuleInventory> modules() {
        return modulesById.values().stream()
                .map(registered -> new ModuleInventory(
                        registered.module().id(), registered.module().name(), registered.enabled()))
                .toList();
    }

    List<RegisteredModule> registrations() {
        return List.copyOf(modulesById.values());
    }

    private static TreeMap<String, PlatformModule> discover(Collection<? extends PlatformModule> modules) {
        TreeMap<String, PlatformModule> discoveredModules = new TreeMap<>();
        for (PlatformModule module : modules) {
            validateMetadata(module);
            PlatformModule previous = discoveredModules.putIfAbsent(module.id(), module);
            if (previous != null) {
                throw new IllegalArgumentException("Duplicate platform module id: " + module.id());
            }
        }
        return discoveredModules;
    }

    private static void validateMetadata(PlatformModule module) {
        Objects.requireNonNull(module, "platform module must not be null");
        requireText(module.id(), "module id");
        requireText(module.name(), "module name");
    }

    private static void validateConfiguredIds(
            NavigableMap<String, PlatformModule> discoveredModules,
            Map<String, Boolean> configuredActivation) {
        List<String> unknownIds = new ArrayList<>();
        for (String configuredId : configuredActivation.keySet()) {
            requireText(configuredId, "configured module id");
            if (!discoveredModules.containsKey(configuredId)) {
                unknownIds.add(configuredId);
            }
        }
        if (!unknownIds.isEmpty()) {
            Collections.sort(unknownIds);
            throw new IllegalArgumentException("Configuration references unknown platform module ids: " + unknownIds);
        }
    }

    private static void validateCore(
            NavigableMap<String, PlatformModule> discoveredModules,
            Map<String, Boolean> configuredActivation) {
        if (!discoveredModules.containsKey(CORE_MODULE_ID)
                || !configuredActivation.getOrDefault(CORE_MODULE_ID, true)) {
            throw new IllegalStateException("The core platform module is mandatory and must be enabled");
        }
    }

    private static void requireText(String value, String description) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
    }

    record RegisteredModule(PlatformModule module, boolean enabled) {
    }
}
