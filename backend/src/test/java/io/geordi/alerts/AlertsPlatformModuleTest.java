package io.geordi.alerts;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.module.ModuleStatus;
import org.junit.jupiter.api.Test;

class AlertsPlatformModuleTest {

    @Test
    void reportsItsStableIdentityAndWiringHealth() {
        assertThat(new AlertsPlatformModule(() -> true)).satisfies(module -> {
            assertThat(module.id()).isEqualTo("alerts");
            assertThat(module.name()).isEqualTo("Alert Evaluation");
            assertThat(module.healthCheck().check()).isEqualTo(ModuleStatus.UP);
        });
        assertThat(new AlertsPlatformModule(() -> false).healthCheck().check()).isEqualTo(ModuleStatus.DOWN);
    }
}
