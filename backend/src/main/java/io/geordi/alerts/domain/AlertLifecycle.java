package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;

public record AlertLifecycle(
        String policyId,
        String sloId,
        AlertCondition condition,
        ServiceIdentity boundService,
        EvaluationWindow boundWindow,
        AlertLifecycleState state,
        AlertEvaluation latestEvaluation,
        BurnRateEvidence activeEvidence,
        Instant startedAt,
        Instant resolvedAt,
        Instant lastStateChangeAt,
        Instant lastProcessedAt,
        Instant lastEvidenceAt,
        AlertTransition latestTransition) {

    public AlertLifecycle {
        Objects.requireNonNull(policyId, "lifecycle policy id must not be null");
        Objects.requireNonNull(sloId, "lifecycle SLO id must not be null");
        Objects.requireNonNull(condition, "lifecycle condition must not be null");
        Objects.requireNonNull(state, "lifecycle state must not be null");
        Objects.requireNonNull(latestEvaluation, "lifecycle latest evaluation must not be null");
        Objects.requireNonNull(lastProcessedAt, "lifecycle last processed time must not be null");
        if (!policyId.equals(latestEvaluation.policyId()) || !sloId.equals(latestEvaluation.sloId())) {
            throw new IllegalArgumentException("lifecycle binding and latest evaluation must match");
        }
        requireConditionBinding(condition, latestEvaluation.condition());
        if ((boundService == null) != (boundWindow == null)) {
            throw new IllegalArgumentException("lifecycle evidence binding must be complete");
        }
        if (boundService != null && lastEvidenceAt == null) {
            throw new IllegalArgumentException("bound lifecycle must retain its latest evidence time");
        }
        if (latestEvaluation.evidence() != null) {
            requireEvidenceBinding(latestEvaluation.evidence(), boundService, boundWindow);
            if (!latestEvaluation.evidence().evaluatedAt().equals(lastEvidenceAt)) {
                throw new IllegalArgumentException("latest evidence time must be retained exactly");
            }
        }
        if (state == AlertLifecycleState.FIRING) {
            Objects.requireNonNull(startedAt, "firing lifecycle must have a start time");
            Objects.requireNonNull(activeEvidence, "firing lifecycle must retain active evidence");
            if (!activeEvidence.available()) {
                throw new IllegalArgumentException("active lifecycle evidence must be available");
            }
            requireEvidenceBinding(activeEvidence, boundService, boundWindow);
            if (resolvedAt != null) {
                throw new IllegalArgumentException("firing lifecycle must not have a resolution time");
            }
        } else if (startedAt != null || activeEvidence != null) {
            throw new IllegalArgumentException("inactive lifecycle must not retain an active episode");
        }
        if (latestTransition != null
                && (!policyId.equals(latestTransition.policyId()) || latestTransition.currentState() != state)) {
            throw new IllegalArgumentException("latest transition must belong to the current lifecycle");
        }
        if (latestTransition != null) {
            requireConditionBinding(condition, latestTransition.evaluation().condition());
        }
    }

    private static void requireEvidenceBinding(
            BurnRateEvidence evidence, ServiceIdentity boundService, EvaluationWindow boundWindow) {
        if (!evidence.service().equals(boundService) || evidence.window() != boundWindow) {
            throw new IllegalArgumentException("lifecycle evidence must match its immutable binding");
        }
    }

    private static void requireConditionBinding(AlertCondition expected, AlertCondition actual) {
        if (expected.type() != actual.type() || expected.threshold().compareTo(actual.threshold()) != 0) {
            throw new IllegalArgumentException("lifecycle condition binding must remain immutable");
        }
    }
}
