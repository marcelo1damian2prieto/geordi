package io.geordi.bootstrap;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class ModuleConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withUserConfiguration(ModuleConfiguration.class);

    @Test
    void defaultsKnownModulesToEnabled() {
        contextRunner.run(context -> {
            assertThat(context).hasNotFailed();
            assertThat(context.getBean(io.geordi.core.module.ModuleRegistry.class).modules())
                    .allMatch(io.geordi.core.module.ModuleSnapshot::enabled);
        });
    }

    @Test
    void permitsDisablingSelfObservabilityCapability() {
        contextRunner.withPropertyValues("geordi.modules.self-observability.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context.getBean(io.geordi.core.module.ModuleRegistry.class).modules())
                            .filteredOn(module -> module.id().equals("self-observability"))
                            .singleElement()
                            .satisfies(module -> {
                                assertThat(module.enabled()).isFalse();
                                assertThat(module.status()).isEqualTo(io.geordi.core.module.ModuleStatus.DISABLED);
                            });
                });
    }

    @Test
    void rejectsDisablingMandatoryCore() {
        contextRunner.withPropertyValues("geordi.modules.core.enabled=false")
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void rejectsUnknownModuleConfiguration() {
        contextRunner.withPropertyValues("geordi.modules.typo.enabled=true")
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void rejectsInvalidBooleanConfiguration() {
        contextRunner.withPropertyValues("geordi.modules.self-observability.enabled=maybe")
                .run(context -> assertThat(context).hasFailed());
    }
}
