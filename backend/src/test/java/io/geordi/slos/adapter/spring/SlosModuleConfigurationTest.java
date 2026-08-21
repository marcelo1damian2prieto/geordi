package io.geordi.slos.adapter.spring;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.ModuleConfiguration;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealthService;
import io.geordi.metrics.adapter.spring.MetricsModuleConfiguration;
import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import java.util.Properties;
import org.junit.jupiter.api.Test;
import org.springframework.boot.info.BuildProperties;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

class SlosModuleConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withUserConfiguration(
                    ModuleConfiguration.class, MetricsModuleConfiguration.class, SlosModuleConfiguration.class)
            .withBean(BuildProperties.class, SlosModuleConfigurationTest::buildProperties);

    @Test
    void bindsTheExternalYamlShapeAndCreatesTheReadOnlyCapability() {
        runner.withPropertyValues(
                        "geordi.slo.definitions[0].id=checkout-availability",
                        "geordi.slo.definitions[0].name=Checkout availability",
                        "geordi.slo.definitions[0].service.name=checkout",
                        "geordi.slo.definitions[0].service.namespace=commerce",
                        "geordi.slo.definitions[0].service.environment=production",
                        "geordi.slo.definitions[0].sli-type=AVAILABILITY",
                        "geordi.slo.definitions[0].target=0.999",
                        "geordi.slo.definitions[0].window=PT5M",
                        "geordi.slo.definitions[0].enabled=true")
                .run(context -> {
                    assertThat(context).hasNotFailed().hasSingleBean(SloEvaluationUseCase.class);
                    assertThat(context.getBean(SloDefinitionCatalog.class).findAll())
                            .singleElement().satisfies(definition -> {
                                assertThat(definition.id()).isEqualTo("checkout-availability");
                                assertThat(definition.service().namespace()).isEqualTo("commerce");
                                assertThat(definition.target()).isEqualByComparingTo("0.999");
                            });
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("slos", "SLOs", true));
                });
    }

    @Test
    void disabledSlosRemainInInventoryWithoutCapabilityBeans() {
        runner.withPropertyValues("geordi.modules.slos.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed().doesNotHaveBean(SloDefinitionCatalog.class);
                    assertThat(context.getBean(ModuleRegistry.class).modules())
                            .contains(new ModuleInventory("slos", "SLOs", false));
                });
    }

    @Test
    void rejectsUnknownCatalogFieldsInsteadOfDefaultingAMisspelledEnabledFlag() {
        runner.withPropertyValues(
                        "geordi.slo.definitions[0].id=checkout-availability",
                        "geordi.slo.definitions[0].name=Checkout availability",
                        "geordi.slo.definitions[0].service.name=checkout",
                        "geordi.slo.definitions[0].service.namespace=commerce",
                        "geordi.slo.definitions[0].service.environment=production",
                        "geordi.slo.definitions[0].sli-type=AVAILABILITY",
                        "geordi.slo.definitions[0].target=0.999",
                        "geordi.slo.definitions[0].window=PT5M",
                        "geordi.slo.definitions[0].enabeld=false")
                .run(context -> assertThat(context).hasFailed());
    }

    @Test
    void enabledSlosReportDownWithoutTheirConfiguredMetricsDependency() {
        runner.withPropertyValues("geordi.modules.metrics.enabled=false")
                .run(context -> {
                    assertThat(context).hasNotFailed().doesNotHaveBean(SloDefinitionCatalog.class);
                    assertThat(context.getBean(PlatformHealthService.class).health().modules())
                            .filteredOn(module -> module.id().equals("slos"))
                            .singleElement().satisfies(module -> assertThat(module.status()).isEqualTo(ModuleStatus.DOWN));
                });
    }

    private static BuildProperties buildProperties() {
        Properties properties = new Properties();
        properties.setProperty("version", "test-version");
        return new BuildProperties(properties);
    }
}
