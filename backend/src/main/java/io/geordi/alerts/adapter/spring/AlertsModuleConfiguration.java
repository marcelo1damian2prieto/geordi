package io.geordi.alerts.adapter.spring;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.alerts.AlertsPlatformModule;
import io.geordi.alerts.adapter.out.config.AlertPoliciesProperties;
import io.geordi.alerts.adapter.out.config.AlertSchedulingProperties;
import io.geordi.alerts.adapter.in.worker.AlertEvaluationScheduler;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertPolicyCatalog;
import io.geordi.alerts.adapter.out.config.AlertRoutingProperties;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertRoutingAdapter;
import io.geordi.alerts.adapter.out.config.WebhookNotificationProperties;
import io.geordi.alerts.adapter.in.worker.NotificationDeliveryWorker;
import io.geordi.alerts.adapter.out.persistence.H2AlertLifecycleRepository;
import io.geordi.alerts.adapter.out.webhook.HttpWebhookNotificationSender;
import io.geordi.alerts.adapter.out.slos.SlosReliabilityAdapter;
import io.geordi.alerts.adapter.out.telemetry.ObservedAlertEvaluationUseCase;
import io.geordi.alerts.adapter.out.telemetry.ObservedAlertHistoryRepository;
import io.geordi.alerts.adapter.out.telemetry.ObservedAlertLifecycleEvaluationUseCase;
import io.geordi.alerts.adapter.out.telemetry.ObservedAlertRoutingPort;
import io.geordi.alerts.application.AlertEvaluationService;
import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.AlertLifecycleQueryService;
import io.geordi.alerts.application.AlertHistoryQueryService;
import io.geordi.alerts.application.AlertLifecycleService;
import io.geordi.alerts.application.AlertSchedulingSettings;
import io.geordi.alerts.application.SingleFlightAlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.application.AlertPolicyReferenceValidator;
import io.geordi.alerts.application.NotificationDeliveryWorkService;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertHistoryRepository;
import io.geordi.alerts.application.port.out.AlertLifecyclePersistenceHealthProbe;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.application.port.out.AlertRoutingPort;
import io.geordi.alerts.application.port.out.NotificationDeliverySender;
import io.geordi.alerts.application.port.out.NotificationDeliveryWorkRepository;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.SloReferencePort;
import io.geordi.core.module.PlatformModule;
import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import java.time.Clock;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.transaction.support.TransactionTemplate;

@Configuration(proxyBeanMethods = false)
public class AlertsModuleConfiguration {

    @Bean
    PlatformModule alertsPlatformModule(
            ObjectProvider<AlertPolicyCatalog> catalogProvider,
            ObjectProvider<BurnRateEvidencePort> evidenceProvider,
            ObjectProvider<AlertLifecyclePersistenceHealthProbe> persistenceHealthProvider) {
        return new AlertsPlatformModule(
                () -> catalogProvider.getIfAvailable() != null
                        && evidenceProvider.getIfAvailable() != null
                        && persistenceHealthProvider.getIfAvailable(
                                () -> () -> false).isAvailable());
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnExpression(
            "${geordi.modules.alerts.enabled:true} && ${geordi.modules.slos.enabled:true}"
                    + " && ${geordi.modules.metrics.enabled:true}")
    @EnableConfigurationProperties({AlertPoliciesProperties.class, AlertRoutingProperties.class, WebhookNotificationProperties.class, AlertSchedulingProperties.class})
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
        H2AlertLifecycleRepository alertLifecycleRepository(
                JdbcTemplate jdbc, ObjectMapper objectMapper) {
            return new H2AlertLifecycleRepository(
                    jdbc, objectMapper, new TransactionTemplate(new JdbcTransactionManager(jdbc.getDataSource())));
        }

        @Bean
        @Primary
        ObservedAlertHistoryRepository observedAlertHistoryRepository(H2AlertLifecycleRepository repository) {
            return new ObservedAlertHistoryRepository(repository, repository);
        }

        @Bean
        ConfigurationAlertRoutingAdapter alertRoutingAdapter(
                AlertRoutingProperties properties, AlertPolicyCatalog catalog) {
            return new ConfigurationAlertRoutingAdapter(properties, catalog);
        }

        @Bean
        @Primary
        AlertRoutingPort observedAlertRoutingPort(ConfigurationAlertRoutingAdapter routing) {
            return new ObservedAlertRoutingPort(routing);
        }

        @Bean
        AlertLifecycleQueryService alertLifecycleQueryService(
                AlertPolicyCatalog catalog,
                AlertLifecycleRepository repository,
                SloLifecycleBindingPort sloBindings) {
            return new AlertLifecycleQueryService(catalog, repository, sloBindings);
        }

        @Bean
        AlertHistoryQueryService alertHistoryQueryService(AlertHistoryRepository repository) {
            return new AlertHistoryQueryService(repository);
        }

        @Bean
        @Primary
        AlertEvaluationUseCase observedAlertEvaluationUseCase(
                AlertPolicyCatalog catalog, BurnRateEvidencePort evidencePort) {
            return new ObservedAlertEvaluationUseCase(new AlertEvaluationService(catalog, evidencePort));
        }

        @Bean
        AlertLifecycleEvaluationUseCase observedAlertLifecycleEvaluationUseCase(
                AlertPolicyCatalog catalog,
                AlertEvaluationUseCase evaluations,
                AlertLifecycleRepository repository,
                SloLifecycleBindingPort sloBindings,
                Clock sloClock,
                AlertRoutingPort routing) {
            AlertLifecycleService delegate = new AlertLifecycleService(
                    catalog, evaluations, repository, sloBindings, sloClock, routing);
            return new SingleFlightAlertLifecycleEvaluationUseCase(new ObservedAlertLifecycleEvaluationUseCase(delegate));
        }

        @Bean(destroyMethod = "close")
        @ConditionalOnProperty(prefix = "geordi.scheduling.alert", name = "enabled", havingValue = "true")
        AlertEvaluationScheduler alertEvaluationScheduler(AlertPolicyCatalog catalog,
            AlertLifecycleEvaluationUseCase evaluations, AlertSchedulingProperties properties) {
            AlertEvaluationScheduler scheduler = new AlertEvaluationScheduler(catalog, evaluations,
                    new AlertSchedulingSettings(properties.interval(), properties.workerCount(), properties.queueCapacity(),
                            properties.shutdownGracePeriod()));
            scheduler.start();
            return scheduler;
        }

        @Configuration(proxyBeanMethods = false)
        @EnableScheduling
        @ConditionalOnProperty(prefix = "geordi.notification", name = "enabled", havingValue = "true")
        static class EnabledNotificationDeliveryConfiguration {

            @Bean
            NotificationDeliveryWorkService notificationDeliveryWorkService(
                    NotificationDeliveryWorkRepository repository, Clock sloClock) {
                return new NotificationDeliveryWorkService(repository, sloClock);
            }

            @Bean
            NotificationDeliverySender notificationDeliverySender(
                    ConfigurationAlertRoutingAdapter destinations, WebhookNotificationProperties properties,
                    ObjectMapper objectMapper) {
                return new HttpWebhookNotificationSender(destinations, properties, objectMapper);
            }

            @Bean
            NotificationDeliveryWorker notificationDeliveryWorker(
                    NotificationDeliveryWorkService work,
                    NotificationDeliverySender sender,
                    WebhookNotificationProperties properties,
                    Clock sloClock) {
                return new NotificationDeliveryWorker(work, sender, properties, sloClock);
            }
        }
    }
}
