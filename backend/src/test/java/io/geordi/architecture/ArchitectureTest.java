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
                        "io.geordi.bootstrap..", "io.geordi.selfobservability..",
                        "io.geordi.metrics..", "io.geordi.traces..", "io.geordi.logs..",
                        "io.geordi.servicemap..", "io.geordi.slos..")
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
                        "io.signoz..",
                        "io.geordi.traces..",
                        "io.geordi.logs..",
                        "io.geordi.servicemap..")
                .check(productionClasses);
    }

    @Test
    void bootstrapDoesNotKnowOptionalConcreteModules() {
        noClasses().that().resideInAPackage("io.geordi.bootstrap..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.selfobservability..", "io.geordi.metrics..", "io.geordi.traces..",
                        "io.geordi.logs..", "io.geordi.servicemap..", "io.geordi.slos..")
                .check(productionClasses);
    }

    @Test
    void selfObservabilityDoesNotDependOnBootstrap() {
        noClasses().that().resideInAPackage("io.geordi.selfobservability..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.bootstrap..")
                .check(productionClasses);
    }

    @Test
    void metricsDomainAndApplicationAreIndependentFromFrameworkAndProviderAdapters() {
        noClasses().that().resideInAnyPackage(
                        "io.geordi.metrics.domain..", "io.geordi.metrics.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "com.fasterxml.jackson..",
                        "io.opentelemetry..",
                        "java.net.http..",
                        "jakarta.persistence..",
                        "io.geordi.metrics.adapter..")
                .check(productionClasses);
    }

    @Test
    void metricsDomainDependsOnlyOnItselfAndTheJavaRuntime() {
        noClasses().that().resideInAPackage("io.geordi.metrics.domain..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.metrics.application..",
                        "io.geordi.metrics.adapter..",
                        "io.geordi.core..",
                        "io.geordi.bootstrap..",
                        "io.geordi.selfobservability..")
                .check(productionClasses);
    }

    @Test
    void tracesDomainAndApplicationAreIndependentFromFrameworkAndProviderAdapters() {
        noClasses().that().resideInAnyPackage(
                        "io.geordi.traces.domain..", "io.geordi.traces.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "com.fasterxml.jackson..",
                        "io.opentelemetry..",
                        "java.net.http..",
                        "jakarta.persistence..",
                        "io.geordi.traces.adapter..")
                .check(productionClasses);
    }

    @Test
    void tracesDomainDependsOnlyOnItselfAndTheJavaRuntime() {
        noClasses().that().resideInAPackage("io.geordi.traces.domain..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.traces.application..",
                        "io.geordi.traces.adapter..",
                        "io.geordi.core..",
                        "io.geordi.bootstrap..",
                        "io.geordi.metrics..",
                        "io.geordi.selfobservability..")
                .check(productionClasses);
    }

    @Test
    void metricsAndTracesDoNotDependOnEachOther() {
        noClasses().that().resideInAPackage("io.geordi.metrics..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.traces..")
                .check(productionClasses);
        noClasses().that().resideInAPackage("io.geordi.traces..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.metrics..")
                .check(productionClasses);
    }

    @Test
    void logsDomainAndApplicationAreIndependentFromFrameworkAndProviderAdapters() {
        noClasses().that().resideInAnyPackage(
                        "io.geordi.logs.domain..", "io.geordi.logs.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "com.fasterxml.jackson..",
                        "com.grafana..",
                        "com.github.loki4j..",
                        "io.loki..",
                        "io.opentelemetry..",
                        "java.net.http..",
                        "jakarta.persistence..",
                        "org.grafana..",
                        "io.geordi.logs.adapter..",
                        "io.geordi.metrics..",
                        "io.geordi.traces..")
                .check(productionClasses);
    }

    @Test
    void logsDomainDependsOnlyOnItselfAndTheJavaRuntime() {
        noClasses().that().resideInAPackage("io.geordi.logs.domain..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.logs.application..",
                        "io.geordi.logs.adapter..",
                        "io.geordi.core..",
                        "io.geordi.bootstrap..",
                        "io.geordi.metrics..",
                        "io.geordi.traces..",
                        "io.geordi.selfobservability..")
                .check(productionClasses);
    }

    @Test
    void logsMetricsAndTracesDoNotDependOnEachOther() {
        noClasses().that().resideInAPackage("io.geordi.logs..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.metrics..", "io.geordi.traces..")
                .check(productionClasses);
        noClasses().that().resideInAnyPackage("io.geordi.metrics..", "io.geordi.traces..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.logs..")
                .check(productionClasses);
    }

    @Test
    void serviceMapDomainAndApplicationAreFrameworkAndSignalIndependent() {
        noClasses().that().resideInAnyPackage(
                        "io.geordi.servicemap.domain..", "io.geordi.servicemap.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "com.fasterxml.jackson..",
                        "io.opentelemetry..",
                        "java.net.http..",
                        "jakarta.persistence..",
                        "io.geordi.servicemap.adapter..",
                        "io.geordi.traces..",
                        "io.geordi.logs..",
                        "io.geordi.metrics..",
                        "io.tempo..",
                        "org.grafana..",
                        "io.loki..")
                .check(productionClasses);
    }

    @Test
    void tracesDoNotDependOnServiceMapAndProviderSyntaxStaysOutsideServiceMapCore() {
        noClasses().that().resideInAPackage("io.geordi.traces..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.servicemap..")
                .check(productionClasses);
        noClasses().that().resideInAnyPackage(
                        "io.geordi.servicemap.domain..", "io.geordi.servicemap.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.traces.adapter.out.tempo..", "io.tempo..")
                .check(productionClasses);
    }

    @Test
    void slosDomainAndApplicationAreFrameworkProviderAndSignalIndependent() {
        noClasses().that().resideInAnyPackage("io.geordi.slos.domain..", "io.geordi.slos.application..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "org.springframework..",
                        "com.fasterxml.jackson..",
                        "io.opentelemetry..",
                        "java.net.http..",
                        "jakarta.persistence..",
                        "io.geordi.slos.adapter..",
                        "io.geordi.metrics..",
                        "io.geordi.traces..",
                        "io.geordi.logs..",
                        "io.geordi.servicemap..",
                        "io.victoriametrics..",
                        "io.prometheus..",
                        "org.grafana..")
                .check(productionClasses);
    }

    @Test
    void slosMetricsCompositionCannotReachProviderAdaptersAndMetricsDoesNotDependOnSlos() {
        noClasses().that().resideInAPackage("io.geordi.slos.adapter.out.metrics..")
                .should().dependOnClassesThat().resideInAnyPackage(
                        "io.geordi.metrics.adapter..", "io.victoriametrics..", "io.prometheus..")
                .check(productionClasses);
        noClasses().that().resideInAPackage("io.geordi.metrics..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.slos..")
                .check(productionClasses);
        noClasses().that().resideInAPackage("io.geordi.slos..")
                .and().resideOutsideOfPackages(
                        "io.geordi.slos.adapter.out.metrics..", "io.geordi.slos.adapter.spring..")
                .should().dependOnClassesThat().resideInAPackage("io.geordi.metrics..")
                .check(productionClasses);
    }
}
