package io.geordi.bootstrap;

import io.geordi.core.module.CorePlatformModule;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.PlatformModule;
import io.geordi.core.platform.PlatformIdentity;
import io.geordi.selfobservability.SelfObservabilityModule;
import java.util.List;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.info.BuildProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(GeordiModulesProperties.class)
public class ModuleConfiguration {

    private static final Logger LOGGER = LoggerFactory.getLogger(ModuleConfiguration.class);

    @Bean
    PlatformModule corePlatformModule() {
        return new CorePlatformModule();
    }

    @Bean
    PlatformModule selfObservabilityModule(GeordiModulesProperties properties) {
        return new SelfObservabilityModule(properties.selfObservabilityEnabled());
    }

    @Bean
    ModuleRegistry moduleRegistry(List<PlatformModule> modules, GeordiModulesProperties properties) {
        if (!properties.coreEnabled()) {
            throw new IllegalStateException("geordi.modules.core.enabled must be true");
        }
        return new ModuleRegistry(modules, failure -> LOGGER.atWarn()
                .addKeyValue("module.id", failure.moduleId())
                .setCause(failure.cause())
                .log("Platform module health check failed"));
    }

    @Bean
    PlatformIdentity platformIdentity(ObjectProvider<BuildProperties> buildPropertiesProvider) {
        BuildProperties buildProperties = buildPropertiesProvider.getIfAvailable();
        String version = buildProperties == null ? "0.1.0-SNAPSHOT" : buildProperties.getVersion();
        return new PlatformIdentity("geordi", "Geordi", version);
    }
}
