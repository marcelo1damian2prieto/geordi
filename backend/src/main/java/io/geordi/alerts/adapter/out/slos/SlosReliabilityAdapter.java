package io.geordi.alerts.adapter.out.slos;

import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.SloReferencePort;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import io.geordi.slos.application.BoundedObservationWindowRequest;
import io.geordi.slos.application.BoundedWindowedBurnRateUseCase;
import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.SloEvaluation;
import java.time.Duration;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

public final class SlosReliabilityAdapter
        implements BurnRateEvidencePort, SloReferencePort, SloLifecycleBindingPort {

    private final SloEvaluationUseCase evaluations;
    private final BoundedWindowedBurnRateUseCase boundedEvaluations;
    private final SloDefinitionCatalog definitions;

    public SlosReliabilityAdapter(
            SloEvaluationUseCase evaluations,
            BoundedWindowedBurnRateUseCase boundedEvaluations,
            SloDefinitionCatalog definitions) {
        this.evaluations = Objects.requireNonNull(evaluations, "SLO evaluations must not be null");
        this.boundedEvaluations = Objects.requireNonNull(boundedEvaluations, "bounded SLO evaluations must not be null");
        this.definitions = Objects.requireNonNull(definitions, "SLO definitions must not be null");
    }

    @Override
    public BurnRateEvidence evaluate(String sloId) {
        SloEvaluation evaluation = evaluations.evaluate(sloId);
        var burn = evaluation.burnRateEvaluation();
        return new BurnRateEvidence(
                evaluation.sloId(),
                new ServiceIdentity(
                        evaluation.service().name(),
                        evaluation.service().namespace(),
                        evaluation.service().environment()),
                EvaluationWindow.valueOf(evaluation.window().name()),
                new TimeRange(evaluation.range().from(), evaluation.range().to()),
                evaluation.evaluatedAt(),
                burn.burnRate(),
                burn.reason() == null ? null : AlertUnavailableReason.valueOf(burn.reason().name()));
    }

    @Override
    public MultiwindowBurnRateEvidence evaluate(String sloId, Set<AlertObservationWindow> observationWindows) {
        Objects.requireNonNull(observationWindows, "alert observation windows must not be null");
        Set<Duration> durations = observationWindows.stream()
                .sorted(Comparator.comparingInt(AlertObservationWindow::canonicalRank))
                .map(AlertObservationWindow::duration)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        var result = boundedEvaluations.evaluate(sloId, new BoundedObservationWindowRequest(durations));
        List<WindowBurnRateObservation> observations = result.observations().stream()
                .map(observation -> new WindowBurnRateObservation(
                        AlertObservationWindow.from(observation.observationWindow()),
                        new TimeRange(observation.range().from(), observation.range().to()),
                        observation.observedBurnRate(),
                        observation.reason() == null ? null : AlertUnavailableReason.valueOf(observation.reason().name())))
                .toList();
        return MultiwindowBurnRateEvidence.of(
                result.sloId(),
                new ServiceIdentity(
                        result.service().name(), result.service().namespace(), result.service().environment()),
                EvaluationWindow.valueOf(result.configuredSloWindow().name()),
                result.evaluatedAt(),
                observationWindows,
                observations);
    }

    @Override
    public boolean exists(String sloId) {
        return definitions.findById(sloId).isPresent();
    }

    @Override
    public Optional<Binding> findById(String sloId) {
        return definitions.findById(sloId).map(definition -> new Binding(
                definition.id(),
                new ServiceIdentity(
                        definition.service().name(),
                        definition.service().namespace(),
                        definition.service().environment()),
                EvaluationWindow.valueOf(definition.window().name())));
    }
}
