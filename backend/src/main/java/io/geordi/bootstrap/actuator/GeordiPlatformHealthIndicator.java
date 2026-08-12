package io.geordi.bootstrap.actuator;

import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealth;
import io.geordi.core.module.PlatformHealthService;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

@Component
public class GeordiPlatformHealthIndicator implements HealthIndicator {

    private final PlatformHealthService platformHealthService;

    public GeordiPlatformHealthIndicator(PlatformHealthService platformHealthService) {
        this.platformHealthService = platformHealthService;
    }

    @Override
    public Health health() {
        PlatformHealth platformHealth = platformHealthService.health();
        if (platformHealth.status() == ModuleStatus.UP) {
            return Health.up().build();
        }
        return Health.down().build();
    }
}
