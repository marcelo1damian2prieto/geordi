package io.geordi.architecture;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import org.junit.jupiter.api.Test;

class ArchitectureTest {

    private final JavaClasses productionClasses = new ClassFileImporter()
            .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
            .importPackages("io.geordi");

    @Test
    void coreDoesNotDependOnBootstrapOrSelfObservability() {
        noClasses().that().resideInAPackage("io.geordi.core..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.bootstrap..", "io.geordi.selfobservability..")
                .check(productionClasses);
    }

    @Test
    void domainAndModuleImplementationsDoNotDependOnFrameworkInfrastructureOrVendors() {
        noClasses().that().resideInAnyPackage("io.geordi.core..", "io.geordi.selfobservability..")
                .and().resideOutsideOfPackage("io.geordi.selfobservability.adapter..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "io.opentelemetry..",
                        "jakarta.persistence..",
                        "java.net.http..",
                        "org.apache.http..",
                        "okhttp3..",
                        "io.prometheus..",
                        "org.grafana..",
                        "io.loki..",
                        "io.tempo..",
                        "com.datadog..",
                        "com.dynatrace..",
                        "io.signoz..")
                .check(productionClasses);
    }

    @Test
    void bootstrapDoesNotKnowOptionalConcreteModules() {
        noClasses().that().resideInAPackage("io.geordi.bootstrap..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.selfobservability..")
                .check(productionClasses);
    }

    @Test
    void selfObservabilityDoesNotDependOnBootstrap() {
        noClasses().that().resideInAPackage("io.geordi.selfobservability..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.bootstrap..")
                .check(productionClasses);
    }
}
