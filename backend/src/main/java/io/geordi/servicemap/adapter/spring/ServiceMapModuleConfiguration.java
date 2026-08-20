package io.geordi.servicemap.adapter.spring;

import io.geordi.core.module.PlatformModule;
import io.geordi.servicemap.ServiceMapPlatformModule;
import io.geordi.servicemap.adapter.out.telemetry.ObservedServiceMapUseCase;
import io.geordi.servicemap.adapter.out.traces.TracesTraceEvidenceAdapter;
import io.geordi.servicemap.application.ServiceMapQueryService;
import io.geordi.servicemap.application.ServiceMapUseCase;
import io.geordi.servicemap.application.port.out.TraceEvidencePort;
import io.geordi.traces.application.TraceDependencyQueryService;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;

@Configuration(proxyBeanMethods = false)
public class ServiceMapModuleConfiguration {

    @Bean
    PlatformModule serviceMapPlatformModule(ObjectProvider<TraceEvidencePort> evidenceProvider) {
        return new ServiceMapPlatformModule(() -> evidenceProvider.getIfAvailable() != null);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnExpression(
            "${geordi.modules.service-map.enabled:true} && ${geordi.modules.traces.enabled:true}")
    static class EnabledServiceMapConfiguration {

        @Bean
        TraceEvidencePort traceEvidencePort(TraceDependencyQueryService traces) {
            return new TracesTraceEvidenceAdapter(traces);
        }

        @Bean
        @Primary
        ServiceMapUseCase observedServiceMapUseCase(TraceEvidencePort evidencePort) {
            ServiceMapQueryService delegate = new ServiceMapQueryService(evidencePort);
            return new ObservedServiceMapUseCase(delegate::query);
        }
    }
}
