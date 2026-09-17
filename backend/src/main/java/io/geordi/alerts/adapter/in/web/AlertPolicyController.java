package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertEvidence;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.BurnRateBandOutcome;
import io.geordi.alerts.domain.BurnRateBandResult;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.WindowBurnRateObservation;
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

    public sealed interface AlertConditionResponse
            permits LegacyAlertConditionResponse, MultiwindowAlertConditionResponse {

        static AlertConditionResponse from(AlertCondition condition) {
            return switch (condition) {
                case BurnRateAboveCondition legacy ->
                    new LegacyAlertConditionResponse(legacy.type().name(), legacy.threshold());
                case MultiwindowBurnRateCondition multiwindow -> new MultiwindowAlertConditionResponse(
                    multiwindow.type().name(), multiwindow.bands().stream().map(BurnRateBandResponse::from).toList());
            };
        }
    }

    public record LegacyAlertConditionResponse(String type, BigDecimal threshold)
            implements AlertConditionResponse {
    }

    public record MultiwindowAlertConditionResponse(String type, List<BurnRateBandResponse> bands)
            implements AlertConditionResponse {
    }

    public record BurnRateBandResponse(String longWindow, String shortWindow, BigDecimal threshold) {

        static BurnRateBandResponse from(BurnRateBand band) {
            return new BurnRateBandResponse(
                    band.longWindow().value(), band.shortWindow().value(), band.threshold());
        }
    }

    public sealed interface AlertEvaluationResponse
            permits LegacyAlertEvaluationResponse, MultiwindowAlertEvaluationResponse {

        static AlertEvaluationResponse from(AlertEvaluation evaluation) {
            if (evaluation.condition() instanceof MultiwindowBurnRateCondition) {
                return new MultiwindowAlertEvaluationResponse(
                        evaluation.policyId(), evaluation.policyName(), evaluation.sloId(),
                        AlertConditionResponse.from(evaluation.condition()), evaluation.status(), evaluation.reason(),
                        evaluation.evidence() == null ? null : AlertEvidenceResponse.from(evaluation.evidence()),
                        evaluation.bandResults().stream().map(BurnRateBandResultResponse::from).toList());
            }
            return new LegacyAlertEvaluationResponse(
                    evaluation.policyId(), evaluation.policyName(), evaluation.sloId(),
                    AlertConditionResponse.from(evaluation.condition()), evaluation.status(), evaluation.reason(),
                    evaluation.evidence() == null ? null : AlertEvidenceResponse.from(evaluation.evidence()));
        }
    }

    public record LegacyAlertEvaluationResponse(
            String policyId,
            String policyName,
            String sloId,
            AlertConditionResponse condition,
            AlertEvaluationStatus status,
            AlertUnavailableReason reason,
            AlertEvidenceResponse evidence) implements AlertEvaluationResponse {
    }

    public record MultiwindowAlertEvaluationResponse(
            String policyId,
            String policyName,
            String sloId,
            AlertConditionResponse condition,
            AlertEvaluationStatus status,
            AlertUnavailableReason reason,
            AlertEvidenceResponse evidence,
            List<BurnRateBandResultResponse> bandResults) implements AlertEvaluationResponse {
    }

    public sealed interface AlertEvidenceResponse
            permits LegacyAlertEvidenceResponse, MultiwindowAlertEvidenceResponse {

        static AlertEvidenceResponse from(AlertEvidence evidence) {
            return switch (evidence) {
                case BurnRateEvidence legacy -> LegacyAlertEvidenceResponse.from(legacy);
                case MultiwindowBurnRateEvidence multiwindow -> MultiwindowAlertEvidenceResponse.from(multiwindow);
            };
        }
    }

    public record LegacyAlertEvidenceResponse(
            ServiceIdentity service,
            String window,
            RangeResponse range,
            String evaluatedAt,
            BigDecimal observedBurnRate) implements AlertEvidenceResponse {

        static LegacyAlertEvidenceResponse from(BurnRateEvidence evidence) {
            return new LegacyAlertEvidenceResponse(
                    evidence.service(), evidence.window().value(),
                    RangeResponse.from(evidence.range()),
                    evidence.evaluatedAt().toString(), evidence.observedBurnRate());
        }
    }

    public record MultiwindowAlertEvidenceResponse(
            ServiceIdentity service,
            String configuredSloWindow,
            String evaluatedAt,
            List<WindowBurnRateObservationResponse> observations) implements AlertEvidenceResponse {

        static MultiwindowAlertEvidenceResponse from(MultiwindowBurnRateEvidence evidence) {
            return new MultiwindowAlertEvidenceResponse(
                    evidence.service(), evidence.configuredSloWindow().value(), evidence.evaluatedAt().toString(),
                    evidence.observations().stream().map(WindowBurnRateObservationResponse::from).toList());
        }
    }

    public record WindowBurnRateObservationResponse(
            String observationWindow,
            RangeResponse range,
            BigDecimal observedBurnRate,
            AlertUnavailableReason reason) {

        static WindowBurnRateObservationResponse from(WindowBurnRateObservation observation) {
            return new WindowBurnRateObservationResponse(
                    observation.observationWindow().value(), RangeResponse.from(observation.range()),
                    observation.observedBurnRate(), observation.reason());
        }
    }

    public record BurnRateBandResultResponse(
            BurnRateBandResponse band,
            WindowBurnRateObservationResponse longObservation,
            WindowBurnRateObservationResponse shortObservation,
            BurnRateBandOutcome outcome) {

        static BurnRateBandResultResponse from(BurnRateBandResult result) {
            return new BurnRateBandResultResponse(
                    BurnRateBandResponse.from(result.band()),
                    WindowBurnRateObservationResponse.from(result.longObservation()),
                    WindowBurnRateObservationResponse.from(result.shortObservation()),
                    result.outcome());
        }
    }

    public record RangeResponse(String from, String to) {

        static RangeResponse from(io.geordi.alerts.domain.TimeRange range) {
            return new RangeResponse(range.from().toString(), range.to().toString());
        }
    }
}
