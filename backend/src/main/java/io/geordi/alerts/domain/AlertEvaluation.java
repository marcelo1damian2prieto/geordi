package io.geordi.alerts.domain;

import java.util.Objects;

public record AlertEvaluation(
        String policyId,
        String policyName,
        String sloId,
        AlertCondition condition,
        AlertEvaluationStatus status,
        AlertUnavailableReason reason,
        BurnRateEvidence evidence) {

    public AlertEvaluation {
        Objects.requireNonNull(policyId, "policy id must not be null");
        Objects.requireNonNull(policyName, "policy name must not be null");
        Objects.requireNonNull(sloId, "SLO id must not be null");
        Objects.requireNonNull(condition, "condition must not be null");
        Objects.requireNonNull(status, "evaluation status must not be null");
        if (evidence != null && !sloId.equals(evidence.sloId())) {
            throw new IllegalArgumentException("evaluation and evidence SLO ids must match");
        }
        if (status == AlertEvaluationStatus.UNAVAILABLE) {
            Objects.requireNonNull(reason, "unavailable evaluation reason must not be null");
            if (reason == AlertUnavailableReason.DISABLED) {
                if (evidence != null) {
                    throw new IllegalArgumentException("disabled policy evaluation must omit evidence");
                }
            } else if (evidence == null || evidence.available() || reason != evidence.reason()) {
                throw new IllegalArgumentException(
                        "unavailable evaluation requires matching unavailable evidence");
            }
        } else if (reason != null || evidence == null || !evidence.available()) {
            throw new IllegalArgumentException("condition result requires available evidence and no reason");
        }
    }
}
