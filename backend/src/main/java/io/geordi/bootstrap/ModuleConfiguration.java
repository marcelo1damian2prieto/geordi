package io.geordi.bootstrap;

import io.geordi.core.module.CorePlatformModule;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.PlatformHealthService;
import io.geordi.core.module.PlatformModule;
import io.geordi.core.platform.PlatformIdentity;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.info.BuildProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(GeordiModulesProperties.class)
public class ModuleConfiguration {

    private static final Logger LOGGER = LoggerFactory.getLogger(ModuleConfiguration.class);

    @Bean
    PlatformModule corePlatformModule() {
        return new CorePlatformModule();
    }

    @Bean
    ModuleRegistry moduleRegistry(List<PlatformModule> modules, GeordiModulesProperties properties) {
        return new ModuleRegistry(modules, properties.activation());
    }

    @Bean
    PlatformHealthService platformHealthService(ModuleRegistry moduleRegistry) {
        return new PlatformHealthService(moduleRegistry, failure -> LOGGER.atWarn()
                .addKeyValue("module.id", failure.moduleId())
                .setCause(failure.cause())
                .log("Platform module health check failed"));
    }

    @Bean
    PlatformIdentity platformIdentity(BuildProperties buildProperties) {
        return new PlatformIdentity("geordi", "Geordi", buildProperties.getVersion());
    }
}
