package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.AlertRoutingPort;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertLifecycleDecision;
import io.geordi.alerts.domain.AlertHistoryMutation;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.AlertLifecycleBindingMismatchException;
import io.geordi.alerts.domain.AlertPolicy;
import java.time.Clock;
import java.time.Instant;
import java.util.Objects;
import java.util.Optional;

public final class AlertLifecycleService implements AlertLifecycleEvaluationUseCase {

    static final int MAXIMUM_UPDATE_ATTEMPTS = 32;

    private final AlertPolicyCatalog catalog;
    private final AlertEvaluationUseCase evaluations;
    private final AlertLifecycleRepository repository;
    private final SloLifecycleBindingPort sloBindings;
    private final Clock clock;
    private final AlertRoutingPort routing;

    public AlertLifecycleService(
            AlertPolicyCatalog catalog,
            AlertEvaluationUseCase evaluations,
            AlertLifecycleRepository repository,
            SloLifecycleBindingPort sloBindings,
            Clock clock) {
        this(catalog, evaluations, repository, sloBindings, clock, ignored -> io.geordi.alerts.domain.RoutingDecision.unrouted());
    }

    public AlertLifecycleService(
            AlertPolicyCatalog catalog,
            AlertEvaluationUseCase evaluations,
            AlertLifecycleRepository repository,
            SloLifecycleBindingPort sloBindings,
            Clock clock,
            AlertRoutingPort routing) {
        this.catalog = Objects.requireNonNull(catalog, "alert policy catalog must not be null");
        this.evaluations = Objects.requireNonNull(evaluations, "alert evaluations must not be null");
        this.repository = Objects.requireNonNull(repository, "alert lifecycle repository must not be null");
        this.sloBindings = Objects.requireNonNull(sloBindings, "SLO lifecycle bindings must not be null");
        this.clock = Objects.requireNonNull(clock, "lifecycle clock must not be null");
        this.routing = Objects.requireNonNull(routing, "alert routing must not be null");
    }

    @Override
    public AlertLifecycleEvaluationResult evaluate(String policyId) {
        AlertPolicy policy = catalog.findById(policyId).orElseThrow(AlertPolicyNotFoundException::new);
        var currentSloBinding = sloBindings.findById(policy.sloId())
                .orElseThrow(AlertLifecycleBindingMismatchException::new);
        AlertEvaluation evaluation = evaluations.evaluate(policyId);
        validateEvaluationBinding(policy, evaluation);
        Instant disabledProcessedAt = evaluation.evidence() == null ? clock.instant() : null;
        for (int attempt = 0; attempt < MAXIMUM_UPDATE_ATTEMPTS; attempt++) {
            Optional<VersionedAlertLifecycle> stored = repository.findByPolicyId(policyId);
            AlertLifecycleDecision decision = AlertLifecycleTransitions.apply(
                    stored.map(VersionedAlertLifecycle::lifecycle), evaluation, disabledProcessedAt);
            AlertLifecycleSnapshot.validateCurrentSloBinding(policy, decision.current(), currentSloBinding);
            if (!decision.writeRequired() || commit(stored, decision)) {
                return new AlertLifecycleEvaluationResult(
                        policy, evaluation, decision.outcome(), decision.current(), decision.transition());
            }
        }
        throw new AlertLifecycleConcurrencyException();
    }

    private static void validateEvaluationBinding(AlertPolicy policy, AlertEvaluation evaluation) {
        boolean sameCondition = policy.condition().type() == evaluation.condition().type()
                && policy.condition().threshold().compareTo(evaluation.condition().threshold()) == 0;
        if (!policy.id().equals(evaluation.policyId())
                || !policy.sloId().equals(evaluation.sloId())
                || !sameCondition) {
            throw new AlertLifecycleBindingMismatchException();
        }
    }

    private boolean commit(
            Optional<VersionedAlertLifecycle> stored, AlertLifecycleDecision decision) {
        return repository.commit(
                decision.current(),
                stored.map(VersionedAlertLifecycle::version),
                notification(decision.transition()),
                Optional.ofNullable(decision.transition()).map(AlertHistoryMutation::from));
    }

    private Optional<NotificationDelivery> notification(AlertTransition transition) {
        if (transition == null) {
            return Optional.empty();
        }
        var decision = routing.route(transition);
        if (decision instanceof io.geordi.alerts.domain.RoutingDecision.Matched matched) {
            return Optional.of(NotificationDelivery.pending(transition, matched.destination(), clock.instant()));
        }
        return Optional.empty();
    }
}
