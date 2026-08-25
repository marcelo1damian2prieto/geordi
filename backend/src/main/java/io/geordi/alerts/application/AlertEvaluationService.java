package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.BurnRateEvidencePort;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import java.util.Objects;

public final class AlertEvaluationService implements AlertEvaluationUseCase {

    private final AlertPolicyCatalog catalog;
    private final BurnRateEvidencePort evidencePort;

    public AlertEvaluationService(AlertPolicyCatalog catalog, BurnRateEvidencePort evidencePort) {
        this.catalog = Objects.requireNonNull(catalog, "alert policy catalog must not be null");
        this.evidencePort = Objects.requireNonNull(evidencePort, "burn-rate evidence port must not be null");
    }

    @Override
    public AlertEvaluation evaluate(String policyId) {
        if (policyId == null || policyId.isBlank()) {
            throw new IllegalArgumentException("alert policy id must not be blank");
        }
        AlertPolicy policy = catalog.findById(policyId).orElseThrow(AlertPolicyNotFoundException::new);
        if (!policy.enabled()) {
            return result(policy, AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.DISABLED, null);
        }
        BurnRateEvidence evidence = Objects.requireNonNull(
                evidencePort.evaluate(policy.sloId()), "burn-rate evidence must not be null");
        if (!policy.sloId().equals(evidence.sloId())) {
            throw new IllegalStateException("burn-rate evidence belongs to another SLO");
        }
        if (!evidence.available()) {
            return result(policy, AlertEvaluationStatus.UNAVAILABLE, evidence.reason(), evidence);
        }
        AlertEvaluationStatus status = evidence.observedBurnRate().compareTo(policy.condition().threshold()) >= 0
                ? AlertEvaluationStatus.CONDITION_MET : AlertEvaluationStatus.CONDITION_NOT_MET;
        return result(policy, status, null, evidence);
    }

    private static AlertEvaluation result(
            AlertPolicy policy,
            AlertEvaluationStatus status,
            AlertUnavailableReason reason,
            BurnRateEvidence evidence) {
        return new AlertEvaluation(
                policy.id(), policy.name(), policy.sloId(), policy.condition(), status, reason, evidence);
    }
}
