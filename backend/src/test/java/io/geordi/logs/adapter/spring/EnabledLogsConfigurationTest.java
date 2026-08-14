package io.geordi.logs.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.logs.application.LogsQueryService;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class EnabledLogsConfigurationTest {

    @Test
    void logsIsEnabledByDefaultAndCapabilityBeansAreCreated() {
        new ApplicationContextRunner()
                .withUserConfiguration(ModuleConfiguration.class, LogsModuleConfiguration.class)
                .withBean(BuildProperties.class, EnabledLogsConfigurationTest::buildProperties)
                .withBean(ObjectMapper.class, ObjectMapper::new)
                .run(context -> {
                    assertThat(context).hasNotFailed().hasSingleBean(LogsQueryService.class);
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("logs", "Logs", true));
                });
    }

    @Test
    void rejectsNonPositiveTimeouts() {
        new ApplicationContextRunner()
                .withUserConfiguration(ModuleConfiguration.class, LogsModuleConfiguration.class)
                .withBean(BuildProperties.class, EnabledLogsConfigurationTest::buildProperties)
                .withBean(ObjectMapper.class, ObjectMapper::new)
                .withPropertyValues("geordi.logs.loki.read-timeout=0s")
                .run(context -> assertThat(context).hasFailed());
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
