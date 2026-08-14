package io.geordi.logs;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.module.ModuleStatus;
import org.junit.jupiter.api.Test;

class LogsPlatformModuleTest {

    @Test
    void exposesStableIdentityAndProbeStatus() {
        LogsPlatformModule module = new LogsPlatformModule(() -> ModuleStatus.UP);

        assertThat(module.id()).isEqualTo("logs");
        assertThat(module.name()).isEqualTo("Logs");
        assertThat(module.healthCheck().check()).isEqualTo(ModuleStatus.UP);
    }
}
