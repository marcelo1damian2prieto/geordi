package io.geordi.servicemap.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.servicemap.application.ServiceMapUseCase;
import io.geordi.traces.adapter.spring.TracesModuleConfiguration;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class ServiceMapModuleConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withUserConfiguration(
                    ModuleConfiguration.class,
                    TracesModuleConfiguration.class,
                    ServiceMapModuleConfiguration.class)
            .withBean(BuildProperties.class, ServiceMapModuleConfigurationTest::buildProperties)
            .withBean(ObjectMapper.class, ObjectMapper::new);

    @Test
    void enablesServiceMapWithItsTraceDependencyByDefault() {
        contextRunner.run(context -> {
            assertThat(context).hasNotFailed().hasSingleBean(ServiceMapUseCase.class);
            assertThat(context.getBean(ModuleRegistry.class).modules())
                    .contains(new ModuleInventory("service-map", "Service Map", true));
        });
    }

    @Test
    void omitsCapabilityBeansWhenItOrTracesAreDisabled() {
        contextRunner.withPropertyValues("geordi.modules.service-map.enabled=false")
                .run(context -> assertThat(context).hasNotFailed().doesNotHaveBean(ServiceMapUseCase.class));
        contextRunner.withPropertyValues("geordi.modules.traces.enabled=false")
                .run(context -> assertThat(context).hasNotFailed().doesNotHaveBean(ServiceMapUseCase.class));
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
