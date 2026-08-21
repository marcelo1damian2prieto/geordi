package io.geordi.slos.adapter.spring;

import io.geordi.core.module.PlatformModule;
import io.geordi.metrics.application.RequestOutcomeQueryService;
import io.geordi.slos.SlosPlatformModule;
import io.geordi.slos.adapter.out.config.ConfigurationSloDefinitionCatalog;
import io.geordi.slos.adapter.out.config.SloDefinitionsProperties;
import io.geordi.slos.adapter.out.metrics.MetricsRequestOutcomeMeasurementAdapter;
import io.geordi.slos.adapter.out.telemetry.ObservedSloEvaluationUseCase;
import io.geordi.slos.application.SloEvaluationService;
import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.SloQueryService;
import io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import java.time.Clock;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;

@Configuration(proxyBeanMethods = false)
public class SlosModuleConfiguration {

    @Bean
    PlatformModule slosPlatformModule(ObjectProvider<SloDefinitionCatalog> catalogProvider,
            ObjectProvider<RequestOutcomeMeasurementPort> measurementProvider) {
        return new SlosPlatformModule(
                () -> catalogProvider.getIfAvailable() != null && measurementProvider.getIfAvailable() != null);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnExpression("${geordi.modules.slos.enabled:true} && ${geordi.modules.metrics.enabled:true}")
    @EnableConfigurationProperties(SloDefinitionsProperties.class)
    static class EnabledSlosConfiguration {

        @Bean
        SloDefinitionCatalog sloDefinitionCatalog(SloDefinitionsProperties properties) {
            return new ConfigurationSloDefinitionCatalog(properties);
        }

        @Bean
        RequestOutcomeMeasurementPort requestOutcomeMeasurementPort(RequestOutcomeQueryService metrics) {
            return new MetricsRequestOutcomeMeasurementAdapter(metrics);
        }

        @Bean
        Clock sloClock() {
            return Clock.systemUTC();
        }

        @Bean
        SloQueryService sloQueryService(SloDefinitionCatalog catalog) {
            return new SloQueryService(catalog);
        }

        @Bean
        @Primary
        SloEvaluationUseCase observedSloEvaluationUseCase(
                SloDefinitionCatalog catalog, RequestOutcomeMeasurementPort measurementPort, Clock sloClock) {
            SloEvaluationService delegate = new SloEvaluationService(catalog, measurementPort, sloClock);
            return new ObservedSloEvaluationUseCase(delegate);
        }
    }
}
