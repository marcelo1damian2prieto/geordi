package io.geordi.alerts.adapter.spring;

import io.geordi.alerts.AlertsPlatformModule;
import io.geordi.alerts.adapter.out.config.AlertPoliciesProperties;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertPolicyCatalog;
import io.geordi.alerts.adapter.out.slos.SlosReliabilityAdapter;
import io.geordi.alerts.adapter.out.telemetry.ObservedAlertEvaluationUseCase;
import io.geordi.alerts.application.AlertEvaluationService;
import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.application.AlertPolicyReferenceValidator;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.application.port.out.SloReferencePort;
import io.geordi.core.module.PlatformModule;
import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;

@Configuration(proxyBeanMethods = false)
public class AlertsModuleConfiguration {

    @Bean
    PlatformModule alertsPlatformModule(
            ObjectProvider<AlertPolicyCatalog> catalogProvider,
            ObjectProvider<BurnRateEvidencePort> evidenceProvider) {
        return new AlertsPlatformModule(
                () -> catalogProvider.getIfAvailable() != null && evidenceProvider.getIfAvailable() != null);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnExpression(
            "${geordi.modules.alerts.enabled:true} && ${geordi.modules.slos.enabled:true}"
                    + " && ${geordi.modules.metrics.enabled:true}")
    @EnableConfigurationProperties(AlertPoliciesProperties.class)
    static class EnabledAlertsConfiguration {

        @Bean
        SlosReliabilityAdapter slosReliabilityAdapter(
                SloEvaluationUseCase evaluations, SloDefinitionCatalog definitions) {
            return new SlosReliabilityAdapter(evaluations, definitions);
        }

        @Bean
        AlertPolicyCatalog alertPolicyCatalog(AlertPoliciesProperties properties, SloReferencePort references) {
            ConfigurationAlertPolicyCatalog catalog = new ConfigurationAlertPolicyCatalog(properties);
            new AlertPolicyReferenceValidator(references).validate(catalog.findAll());
            return catalog;
        }

        @Bean
        AlertPolicyQueryService alertPolicyQueryService(AlertPolicyCatalog catalog) {
            return new AlertPolicyQueryService(catalog);
        }

        @Bean
        @Primary
        AlertEvaluationUseCase observedAlertEvaluationUseCase(
                AlertPolicyCatalog catalog, BurnRateEvidencePort evidencePort) {
            return new ObservedAlertEvaluationUseCase(new AlertEvaluationService(catalog, evidencePort));
        }
    }
}
