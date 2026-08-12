package io.geordi.bootstrap;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi", ignoreUnknownFields = false)
public record GeordiModulesProperties(Map<String, ModuleSettings> modules) {

    public GeordiModulesProperties {
        modules = modules == null ? Map.of() : Map.copyOf(modules);
    }

    public Map<String, Boolean> activation() {
        Map<String, Boolean> activation = new LinkedHashMap<>();
        modules.forEach((id, settings) -> activation.put(id, enabledByDefault(settings)));
        return Map.copyOf(activation);
    }

    private static boolean enabledByDefault(ModuleSettings settings) {
        return settings == null || settings.enabled() == null || settings.enabled();
    }

    public record ModuleSettings(Boolean enabled) {
    }
}
