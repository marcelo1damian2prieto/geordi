package io.geordi.bootstrap.actuator;

import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealth;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

@Component
public class GeordiPlatformHealthIndicator implements HealthIndicator {

    private final ModuleRegistry moduleRegistry;

    public GeordiPlatformHealthIndicator(ModuleRegistry moduleRegistry) {
        this.moduleRegistry = moduleRegistry;
    }

    @Override
    public Health health() {
        PlatformHealth platformHealth = moduleRegistry.health();
        if (platformHealth.status() == ModuleStatus.UP) {
            return Health.up().build();
        }
        return Health.down().build();
    }
}
