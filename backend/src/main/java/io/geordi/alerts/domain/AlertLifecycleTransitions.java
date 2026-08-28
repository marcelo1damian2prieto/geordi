package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;
import java.util.Optional;

public final class AlertLifecycleTransitions {

    private AlertLifecycleTransitions() {
    }

    public static AlertLifecycleDecision apply(
            Optional<AlertLifecycle> previousValue,
            AlertEvaluation evaluation,
            Instant disabledProcessedAt) {
        Objects.requireNonNull(previousValue, "previous lifecycle must not be null");
        Objects.requireNonNull(evaluation, "alert evaluation must not be null");
        AlertLifecycle previous = previousValue.orElse(null);
        validateBinding(previous, evaluation);

        BurnRateEvidence evidence = evaluation.evidence();
        Instant evidenceAt = evidence == null ? null : evidence.evaluatedAt();
        if (evidenceAt == null && evaluation.reason() != AlertUnavailableReason.DISABLED) {
            throw new IllegalArgumentException("only a disabled evaluation may omit evidence time");
        }
        Instant processedAt = evidenceAt == null
                ? Objects.requireNonNull(disabledProcessedAt, "disabled processing time must not be null")
                : evidenceAt;
        AlertLifecycleDecision ignored = ignored(previous, evidenceAt, processedAt);
        if (ignored != null) {
            return ignored;
        }

        AlertLifecycleState previousState = previous == null ? AlertLifecycleState.INACTIVE : previous.state();
        AlertLifecycleState currentState = nextState(previousState, evaluation.status());
        AlertTransition transition = transition(evaluation, previousState, currentState, evidenceAt);
        ServiceIdentity boundService = bindingService(previous, evidence);
        EvaluationWindow boundWindow = bindingWindow(previous, evidence);
        BurnRateEvidence activeEvidence = activeEvidence(previous, evaluation, currentState);
        Instant startedAt = startedAt(previous, currentState, transition);
        Instant resolvedAt = resolvedAt(previous, currentState, transition);
        Instant stateChangedAt = transition == null
                ? previous == null ? null : previous.lastStateChangeAt()
                : transition.occurredAt();
        AlertTransition latestTransition = transition == null
                ? previous == null ? null : previous.latestTransition()
                : transition;
        AlertLifecycle current = new AlertLifecycle(
                evaluation.policyId(), evaluation.sloId(), evaluation.condition(), boundService, boundWindow,
                currentState, evaluation, activeEvidence, startedAt, resolvedAt, stateChangedAt, processedAt,
                evidenceAt == null && previous != null ? previous.lastEvidenceAt() : evidenceAt,
                latestTransition);
        return new AlertLifecycleDecision(AlertLifecycleProcessingOutcome.APPLIED, current, transition, true);
    }

    private static AlertLifecycleDecision ignored(
            AlertLifecycle previous, Instant evidenceAt, Instant processedAt) {
        if (previous == null) {
            return null;
        }
        Instant previousTime = evidenceAt == null ? previous.lastProcessedAt() : previous.lastEvidenceAt();
        if (previousTime == null) {
            return null;
        }
        int order = processedAt.compareTo(previousTime);
        if (order < 0) {
            return new AlertLifecycleDecision(
                    AlertLifecycleProcessingOutcome.STALE_IGNORED, previous, null, false);
        }
        if (order == 0) {
            return new AlertLifecycleDecision(
                    AlertLifecycleProcessingOutcome.DUPLICATE_IGNORED, previous, null, false);
        }
        return null;
    }

    private static AlertLifecycleState nextState(
            AlertLifecycleState previous, AlertEvaluationStatus evaluationStatus) {
        return switch (evaluationStatus) {
            case CONDITION_MET -> AlertLifecycleState.FIRING;
            case CONDITION_NOT_MET -> AlertLifecycleState.INACTIVE;
            case UNAVAILABLE -> previous;
        };
    }

    private static AlertTransition transition(
            AlertEvaluation evaluation,
            AlertLifecycleState previous,
            AlertLifecycleState current,
            Instant occurredAt) {
        if (previous == AlertLifecycleState.INACTIVE && current == AlertLifecycleState.FIRING) {
            return new AlertTransition(
                    evaluation.policyId(), AlertTransitionType.ALERT_STARTED, previous, current,
                    occurredAt, evaluation);
        }
        if (previous == AlertLifecycleState.FIRING && current == AlertLifecycleState.INACTIVE) {
            return new AlertTransition(
                    evaluation.policyId(), AlertTransitionType.ALERT_RESOLVED, previous, current,
                    occurredAt, evaluation);
        }
        return null;
    }

    private static ServiceIdentity bindingService(AlertLifecycle previous, BurnRateEvidence evidence) {
        return previous != null && previous.boundService() != null
                ? previous.boundService()
                : evidence == null ? null : evidence.service();
    }

    private static EvaluationWindow bindingWindow(AlertLifecycle previous, BurnRateEvidence evidence) {
        return previous != null && previous.boundWindow() != null
                ? previous.boundWindow()
                : evidence == null ? null : evidence.window();
    }

    private static BurnRateEvidence activeEvidence(
            AlertLifecycle previous, AlertEvaluation evaluation, AlertLifecycleState current) {
        if (current == AlertLifecycleState.INACTIVE) {
            return null;
        }
        if (evaluation.status() == AlertEvaluationStatus.CONDITION_MET) {
            return evaluation.evidence();
        }
        return previous.activeEvidence();
    }

    private static Instant startedAt(
            AlertLifecycle previous, AlertLifecycleState current, AlertTransition transition) {
        if (current == AlertLifecycleState.INACTIVE) {
            return null;
        }
        return transition != null ? transition.occurredAt() : previous.startedAt();
    }

    private static Instant resolvedAt(
            AlertLifecycle previous, AlertLifecycleState current, AlertTransition transition) {
        if (current == AlertLifecycleState.FIRING) {
            return null;
        }
        return transition != null ? transition.occurredAt() : previous == null ? null : previous.resolvedAt();
    }

    private static void validateBinding(AlertLifecycle previous, AlertEvaluation evaluation) {
        if (previous == null) {
            return;
        }
        boolean sameCondition = previous.condition().type() == evaluation.condition().type()
                && previous.condition().threshold().compareTo(evaluation.condition().threshold()) == 0;
        if (!previous.policyId().equals(evaluation.policyId())
                || !previous.sloId().equals(evaluation.sloId())
                || !sameCondition) {
            throw new AlertLifecycleBindingMismatchException();
        }
        if (evaluation.evidence() != null && previous.boundService() != null
                && (!previous.boundService().equals(evaluation.evidence().service())
                || previous.boundWindow() != evaluation.evidence().window())) {
            throw new AlertLifecycleBindingMismatchException();
        }
    }
}
