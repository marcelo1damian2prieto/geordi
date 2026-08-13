package io.geordi.traces.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.traces.application.TraceQueryService;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class EnabledTracesConfigurationTest {

    @Test
    void tracesIsEnabledByDefaultAndItsCapabilityBeansAreCreated() {
        new ApplicationContextRunner()
                .withUserConfiguration(ModuleConfiguration.class, TracesModuleConfiguration.class)
                .withBean(BuildProperties.class, EnabledTracesConfigurationTest::buildProperties)
                .withBean(ObjectMapper.class, ObjectMapper::new)
                .run(context -> {
                    assertThat(context).hasNotFailed().hasSingleBean(TraceQueryService.class);
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("traces", "Traces", true));
                });
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
