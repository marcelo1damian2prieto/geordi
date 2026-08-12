package io.geordi.bootstrap;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import io.geordi.core.platform.PlatformIdentity;
import io.geordi.selfobservability.adapter.spring.SelfObservabilityModuleConfiguration;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class ModuleConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withUserConfiguration(ModuleConfiguration.class, SelfObservabilityModuleConfiguration.class)
            .withBean(BuildProperties.class, () -> buildProperties("test-version"));

    @Test
    void defaultsDiscoveredModulesToEnabled() {
        contextRunner.run(context -> {
            assertThat(context).hasNotFailed();
            assertThat(context.getBean(ModuleRegistry.class).modules())
                    .containsExactly(
                            new ModuleInventory("core", "Core", true),
                            new ModuleInventory("self-observability", "Self Observability", true));
        });
    }

    @Test
    void genericallyBindsRelaxedModuleIdsAndDisablesAConfiguredModule() {
        contextRunner.withPropertyValues("geordi.modules.self-observability.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .filteredOn(module -> module.id().equals("self-observability"))
                            .containsExactly(new ModuleInventory(
                                    "self-observability", "Self Observability", false));
                });
    }

    @Test
    void discoversFutureModuleBeansWithoutOptionalModuleKnowledgeInCentralConfiguration() {
        contextRunner.withBean("futurePlatformModule", PlatformModule.class,
                        () -> module("future-module", "Future Module"))
                .withPropertyValues("geordi.modules.future-module.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("future-module", "Future Module", false));
                });
    }

    @Test
    void rejectsDisabledCoreUnknownModuleConfigurationAndInvalidBooleanValues() {
        contextRunner.withPropertyValues("geordi.modules.core.enabled=false")
                .run(context -> assertThat(context).hasFailed());
        contextRunner.withPropertyValues("geordi.modules.typo.enabled=true")
                .run(context -> assertThat(context).hasFailed());
        contextRunner.withPropertyValues("geordi.modules.self-observability.enabled=maybe")
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void requiresBuildPropertiesAndUsesItsVersionWithoutFallback() {
        contextRunner.run(context -> assertThat(context.getBean(PlatformIdentity.class).version())
                .isEqualTo("test-version"));

        new ApplicationContextRunner().withUserConfiguration(ModuleConfiguration.class)
                .run(context -> assertThat(context).hasFailed());
    }

    private static BuildProperties buildProperties(String version) {
        Properties properties = new Properties();
        properties.setProperty("version", version);
        return new BuildProperties(properties);
    }

    private static PlatformModule module(String id, String name) {
        return new PlatformModule() {
            @Override
            public String id() {
                return id;
            }

            @Override
            public String name() {
                return name;
            }

            @Override
            public io.geordi.core.module.ModuleHealthCheck healthCheck() {
                return () -> ModuleStatus.UP;
            }
        };
    }
}
