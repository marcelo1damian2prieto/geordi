package io.geordi.servicemap;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.module.ModuleStatus;
import org.junit.jupiter.api.Test;

class ServiceMapPlatformModuleTest {

    @Test
    void reportsConfigurationAvailabilityWithoutProbingTraceStorage() {
        assertThat(new ServiceMapPlatformModule(() -> true).healthCheck().check()).isEqualTo(ModuleStatus.UP);
        assertThat(new ServiceMapPlatformModule(() -> false).healthCheck().check()).isEqualTo(ModuleStatus.DOWN);
    }
}
