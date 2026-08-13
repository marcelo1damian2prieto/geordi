package io.geordi.metrics.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.metrics.application.MetricsQueryService;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class EnabledMetricsConfigurationTest {

    @Test
    void metricsIsEnabledByDefaultAndItsCapabilityBeansAreCreated() {
        new ApplicationContextRunner()
                .withUserConfiguration(ModuleConfiguration.class, MetricsModuleConfiguration.class)
                .withBean(BuildProperties.class, EnabledMetricsConfigurationTest::buildProperties)
                .run(context -> {
                    assertThat(context).hasNotFailed().hasSingleBean(MetricsQueryService.class);
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("metrics", "Metrics", true));
                });
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
