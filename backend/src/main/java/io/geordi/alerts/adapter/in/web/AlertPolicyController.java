package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnExpression(
        "${geordi.modules.alerts.enabled:true} && ${geordi.modules.slos.enabled:true}"
                + " && ${geordi.modules.metrics.enabled:true}")
@RequestMapping("/api/alert-policies")
public class AlertPolicyController {

    private final AlertPolicyQueryService queryService;
    private final AlertEvaluationUseCase evaluationService;

    public AlertPolicyController(AlertPolicyQueryService queryService, AlertEvaluationUseCase evaluationService) {
        this.queryService = queryService;
        this.evaluationService = evaluationService;
    }

    @GetMapping
    public AlertPoliciesResponse list() {
        return new AlertPoliciesResponse(queryService.findAll().stream().map(AlertPolicyResponse::from).toList());
    }

    @GetMapping("/{policyId}/evaluation")
    public AlertEvaluationResponse evaluate(@PathVariable String policyId) {
        return AlertEvaluationResponse.from(evaluationService.evaluate(policyId));
    }

    public record AlertPoliciesResponse(List<AlertPolicyResponse> alertPolicies) {
    }

    public record AlertPolicyResponse(
            String id,
            String name,
            String description,
            boolean enabled,
            String sloId,
            AlertConditionResponse condition) {

        static AlertPolicyResponse from(AlertPolicy policy) {
            return new AlertPolicyResponse(
                    policy.id(), policy.name(), policy.description(), policy.enabled(), policy.sloId(),
                    AlertConditionResponse.from(policy.condition()));
        }
    }

    public record AlertConditionResponse(String type, BigDecimal threshold) {

        static AlertConditionResponse from(AlertCondition condition) {
            return new AlertConditionResponse(condition.type().name(), condition.threshold());
        }
    }

    public record AlertEvaluationResponse(
            String policyId,
            String policyName,
            String sloId,
            AlertConditionResponse condition,
            AlertEvaluationStatus status,
            AlertUnavailableReason reason,
            AlertEvidenceResponse evidence) {

        static AlertEvaluationResponse from(AlertEvaluation evaluation) {
            return new AlertEvaluationResponse(
                    evaluation.policyId(), evaluation.policyName(), evaluation.sloId(),
                    AlertConditionResponse.from(evaluation.condition()), evaluation.status(), evaluation.reason(),
                    evaluation.evidence() == null ? null : AlertEvidenceResponse.from(evaluation.evidence()));
        }
    }

    public record AlertEvidenceResponse(
            ServiceIdentity service,
            String window,
            RangeResponse range,
            String evaluatedAt,
            BigDecimal observedBurnRate) {

        static AlertEvidenceResponse from(BurnRateEvidence evidence) {
            return new AlertEvidenceResponse(
                    evidence.service(), evidence.window().value(),
                    new RangeResponse(evidence.range().from().toString(), evidence.range().to().toString()),
                    evidence.evaluatedAt().toString(), evidence.observedBurnRate());
        }
    }

    public record RangeResponse(String from, String to) {
    }
}
