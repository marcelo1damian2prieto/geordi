package io.geordi.selfobservability.adapter.spring;

import io.geordi.core.module.PlatformModule;
import io.geordi.selfobservability.SelfObservabilityModule;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration(proxyBeanMethods = false)
public class SelfObservabilityModuleConfiguration {

    @Bean
    PlatformModule selfObservabilityModule() {
        return new SelfObservabilityModule();
    }
}
