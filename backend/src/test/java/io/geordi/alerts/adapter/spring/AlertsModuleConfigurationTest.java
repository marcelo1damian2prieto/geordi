package io.geordi.alerts.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.application.port.out.AlertLifecyclePersistenceHealthProbe;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealthService;
import io.geordi.metrics.adapter.spring.MetricsModuleConfiguration;
import io.geordi.slos.adapter.spring.SlosModuleConfiguration;
import java.util.List;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.flyway.FlywayAutoConfiguration;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.boot.autoconfigure.jdbc.JdbcTemplateAutoConfiguration;
import org.springframework.boot.autoconfigure.jackson.JacksonAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.jdbc.core.JdbcTemplate;

class AlertsModuleConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(
                    DataSourceAutoConfiguration.class,
                    JdbcTemplateAutoConfiguration.class,
                    FlywayAutoConfiguration.class,
                    JacksonAutoConfiguration.class))
            .withUserConfiguration(
                    ModuleConfiguration.class,
                    MetricsModuleConfiguration.class,
                    SlosModuleConfiguration.class,
                    AlertsModuleConfiguration.class)
            .withBean(BuildProperties.class, AlertsModuleConfigurationTest::buildProperties)
            .withPropertyValues(
                    "spring.datasource.url=jdbc:h2:mem:alerts-configuration;DB_CLOSE_DELAY=-1",
                    "spring.datasource.username=sa",
                    "spring.datasource.password=",
                    "spring.datasource.driver-class-name=org.h2.Driver")
            .withPropertyValues(sloProperties());

    @Test
    void bindsTheExternalYamlShapeAndCreatesTheReadOnlyCapability() {
        runner.withPropertyValues(policyProperties("checkout-availability"))
                .run(context -> {
                    assertThat(context).hasNotFailed().hasSingleBean(AlertEvaluationUseCase.class);
                    assertThat(context.getBean(AlertPolicyCatalog.class).findAll())
                            .singleElement().satisfies(policy -> {
                                assertThat(policy.id()).isEqualTo("checkout-burn");
                                assertThat(policy.sloId()).isEqualTo("checkout-availability");
                                assertThat(policy.condition().threshold()).isEqualByComparingTo("2");
                            });
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("alerts", "Alert Evaluation", true));
                });
    }

    @Test
    void rejectsUnknownSloReferencesAtomicallyAtStartup() {
        runner.withPropertyValues(policyProperties("missing-slo"))
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void rejectsUnknownCatalogFields() {
        runner.withPropertyValues(policyProperties("checkout-availability"))
                .withPropertyValues("geordi.alert.policies[0].enabeld=false")
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void rejectsNonFiniteThresholdProperties() {
        for (String threshold : List.of("NaN", "Infinity", "-Infinity")) {
            runner.withPropertyValues(policyProperties("checkout-availability", threshold))
                    .run(context -> assertThat(context).hasFailed());
        }
    }

    @Test
    void disabledAlertsRemainInInventoryWithoutCapabilityBeans() {
        runner.withPropertyValues("geordi.modules.alerts.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed().doesNotHaveBean(AlertPolicyCatalog.class);
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("alerts", "Alert Evaluation", false));
                });
    }

    @Test
    void enabledAlertsReportDownWithoutTheirSloDependency() {
        runner.withPropertyValues("geordi.modules.slos.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed().doesNotHaveBean(AlertPolicyCatalog.class);
                    assertThat(context.getBean(PlatformHealthService.class).health().modules())
                            .filteredOn(module -> module.id().equals("alerts"))
                            .singleElement().satisfies(module -> assertThat(module.status()).isEqualTo(ModuleStatus.DOWN));
                });
    }

    @Test
    void reportsActualLifecyclePersistenceOutageThroughAlertsHealth() {
        runner.run(context -> {
            assertThat(context).hasNotFailed().hasSingleBean(AlertLifecyclePersistenceHealthProbe.class);
            assertThat(context.getBean(PlatformHealthService.class).health().modules())
                    .filteredOn(module -> module.id().equals("alerts"))
                    .singleElement().satisfies(module -> assertThat(module.status()).isEqualTo(ModuleStatus.UP));

            JdbcTemplate jdbc = context.getBean(JdbcTemplate.class);
            jdbc.execute("ALTER TABLE alert_lifecycle_state RENAME TO alert_lifecycle_state_unavailable");
            try {
                assertThat(context.getBean(AlertLifecyclePersistenceHealthProbe.class).isAvailable()).isFalse();
                assertThat(context.getBean(PlatformHealthService.class).health().modules())
                        .filteredOn(module -> module.id().equals("alerts"))
                        .singleElement().satisfies(module -> assertThat(module.status()).isEqualTo(ModuleStatus.DOWN));
                assertThatThrownBy(() -> context.getBean(AlertLifecycleRepository.class).findAll())
                        .isInstanceOf(AlertLifecyclePersistenceException.class);
            } finally {
                jdbc.execute("ALTER TABLE alert_lifecycle_state_unavailable RENAME TO alert_lifecycle_state");
            }
        });
    }

    private static String[] sloProperties() {
        return new String[] {
            "geordi.slo.definitions[0].id=checkout-availability",
            "geordi.slo.definitions[0].name=Checkout availability",
            "geordi.slo.definitions[0].service.name=checkout",
            "geordi.slo.definitions[0].service.namespace=commerce",
            "geordi.slo.definitions[0].service.environment=production",
            "geordi.slo.definitions[0].sli-type=AVAILABILITY",
            "geordi.slo.definitions[0].target=0.99",
            "geordi.slo.definitions[0].window=PT5M",
            "geordi.slo.definitions[0].enabled=true"
        };
    }

    private static String[] policyProperties(String sloId) {
        return policyProperties(sloId, "2");
    }

    private static String[] policyProperties(String sloId, String threshold) {
        return new String[] {
            "geordi.alert.policies[0].id=checkout-burn",
            "geordi.alert.policies[0].name=Checkout burn",
            "geordi.alert.policies[0].enabled=true",
            "geordi.alert.policies[0].slo-id=" + sloId,
            "geordi.alert.policies[0].condition.type=BURN_RATE_ABOVE",
            "geordi.alert.policies[0].condition.threshold=" + threshold
        };
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
