package io.geordi.alerts.domain;

import java.util.List;
import java.util.Objects;

public record AlertEvaluation(
        String policyId,
        String policyName,
        String sloId,
        AlertCondition condition,
        AlertEvaluationStatus status,
        AlertUnavailableReason reason,
        AlertEvidence evidence) {

    public AlertEvaluation {
        Objects.requireNonNull(policyId, "policy id must not be null");
        Objects.requireNonNull(policyName, "policy name must not be null");
        Objects.requireNonNull(sloId, "SLO id must not be null");
        Objects.requireNonNull(condition, "condition must not be null");
        Objects.requireNonNull(status, "evaluation status must not be null");
        if (evidence != null && !sloId.equals(evidence.sloId())) {
            throw new IllegalArgumentException("evaluation and evidence SLO ids must match");
        }
        if (condition instanceof BurnRateAboveCondition) {
            validateLegacy(status, reason, evidence);
        } else if (condition instanceof MultiwindowBurnRateCondition multiwindow) {
            validateMultiwindow(multiwindow, status, reason, evidence);
        }
    }

    public List<BurnRateBandResult> bandResults() {
        if (condition instanceof MultiwindowBurnRateCondition multiwindow
                && evidence instanceof MultiwindowBurnRateEvidence multiwindowEvidence) {
            return multiwindow.evaluate(multiwindowEvidence);
        }
        return List.of();
    }

    private static void validateLegacy(
            AlertEvaluationStatus status, AlertUnavailableReason reason, AlertEvidence evidence) {
        if (evidence != null && !(evidence instanceof BurnRateEvidence)) {
            throw new IllegalArgumentException("legacy condition requires scalar burn-rate evidence");
        }
        if (status == AlertEvaluationStatus.UNAVAILABLE) {
            Objects.requireNonNull(reason, "unavailable evaluation reason must not be null");
            if (reason == AlertUnavailableReason.DISABLED) {
                if (evidence != null) {
                    throw new IllegalArgumentException("disabled policy evaluation must omit evidence");
                }
            } else if (!(evidence instanceof BurnRateEvidence scalar)
                    || scalar.available() || reason != scalar.reason()) {
                throw new IllegalArgumentException(
                        "unavailable evaluation requires matching unavailable evidence");
            }
        } else if (reason != null || !(evidence instanceof BurnRateEvidence scalar) || !scalar.available()) {
            throw new IllegalArgumentException("condition result requires available evidence and no reason");
        }
    }

    private static void validateMultiwindow(
            MultiwindowBurnRateCondition condition,
            AlertEvaluationStatus status,
            AlertUnavailableReason reason,
            AlertEvidence evidence) {
        if (reason == AlertUnavailableReason.DISABLED) {
            if (status != AlertEvaluationStatus.UNAVAILABLE || evidence != null) {
                throw new IllegalArgumentException("disabled policy evaluation must omit evidence");
            }
            return;
        }
        if (!(evidence instanceof MultiwindowBurnRateEvidence aggregate)) {
            throw new IllegalArgumentException("multiwindow condition requires aggregate evidence");
        }
        AlertEvaluationStatus derivedStatus = condition.evaluateStatus(aggregate);
        if (status != derivedStatus) {
            throw new IllegalArgumentException("multiwindow evaluation status must match its complete evidence");
        }
        if (status == AlertEvaluationStatus.UNAVAILABLE) {
            if (reason != AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE) {
                throw new IllegalArgumentException("multiwindow unavailable result requires aggregate reason");
            }
        } else if (reason != null) {
            throw new IllegalArgumentException("decisive multiwindow evaluation must not have a reason");
        }
    }
}
