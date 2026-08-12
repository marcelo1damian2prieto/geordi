package io.geordi.bootstrap;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.modules", ignoreUnknownFields = false)
public record GeordiModulesProperties(ModuleSettings core, ModuleSettings selfObservability) {

    public boolean coreEnabled() {
        return enabledByDefault(core);
    }

    public boolean selfObservabilityEnabled() {
        return enabledByDefault(selfObservability);
    }

    private static boolean enabledByDefault(ModuleSettings settings) {
        return settings == null || settings.enabled() == null || settings.enabled();
    }

    public record ModuleSettings(Boolean enabled) {
    }
}
