package io.geordi.traces;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.module.ModuleStatus;
import org.junit.jupiter.api.Test;

class TracesPlatformModuleTest {

    @Test
    void exposesStableIdentityAndTheRealProbeResult() {
        TracesPlatformModule up = new TracesPlatformModule(() -> ModuleStatus.UP);
        TracesPlatformModule down = new TracesPlatformModule(() -> ModuleStatus.DOWN);

        assertThat(up.id()).isEqualTo("traces");
        assertThat(up.name()).isEqualTo("Traces");
        assertThat(up.healthCheck().check()).isEqualTo(ModuleStatus.UP);
        assertThat(down.healthCheck().check()).isEqualTo(ModuleStatus.DOWN);
    }
}
