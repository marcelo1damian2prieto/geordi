package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertLifecycleEvaluationResult;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.AlertLifecycleQueryService;
import io.geordi.alerts.application.AlertLifecycleSnapshot;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleProcessingOutcome;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnExpression(
        "${geordi.modules.alerts.enabled:true} && ${geordi.modules.slos.enabled:true}"
                + " && ${geordi.modules.metrics.enabled:true}")
@RequestMapping("/api")
public class AlertLifecycleController {

    private final AlertLifecycleQueryService queries;
    private final AlertLifecycleEvaluationUseCase evaluations;

    public AlertLifecycleController(
            AlertLifecycleQueryService queries, AlertLifecycleEvaluationUseCase evaluations) {
        this.queries = queries;
        this.evaluations = evaluations;
    }

    @GetMapping("/alert-states")
    public AlertStatesResponse list() {
        return new AlertStatesResponse(queries.findAll().stream().map(AlertLifecycleResponse::from).toList());
    }

    @PostMapping("/alert-policies/{policyId}/lifecycle-evaluations")
    public AlertLifecycleEvaluationResponse evaluate(@PathVariable String policyId) {
        return AlertLifecycleEvaluationResponse.from(evaluations.evaluate(policyId));
    }

    public record AlertStatesResponse(List<AlertLifecycleResponse> alertStates) {
    }

    public record AlertLifecycleEvaluationResponse(
            AlertPolicyController.AlertEvaluationResponse triggeringEvaluation,
            AlertLifecycleProcessingOutcome outcome,
            AlertLifecycleResponse current,
            AlertTransitionResponse transition) {

        static AlertLifecycleEvaluationResponse from(AlertLifecycleEvaluationResult result) {
            return new AlertLifecycleEvaluationResponse(
                    AlertPolicyController.AlertEvaluationResponse.from(result.triggeringEvaluation()),
                    result.outcome(),
                    AlertLifecycleResponse.from(new AlertLifecycleSnapshot(result.policy(), result.current())),
                    result.transition() == null ? null : AlertTransitionResponse.from(result.transition()));
        }
    }

    public record AlertLifecycleResponse(
            AlertPolicyController.AlertPolicyResponse policy,
            boolean initialized,
            AlertLifecycleState state,
            AlertPolicyController.AlertEvaluationResponse latestEvaluation,
            AlertPolicyController.AlertEvidenceResponse activeEvidence,
            String startedAt,
            String resolvedAt,
            String lastStateChangeAt,
            String lastProcessedAt,
            String lastEvidenceAt,
            AlertTransitionResponse latestTransition) {

        static AlertLifecycleResponse from(AlertLifecycleSnapshot snapshot) {
            AlertLifecycle lifecycle = snapshot.lifecycle();
            if (lifecycle == null) {
                return new AlertLifecycleResponse(
                        AlertPolicyController.AlertPolicyResponse.from(snapshot.policy()), false,
                        AlertLifecycleState.INACTIVE, null, null, null, null, null, null, null, null);
            }
            return new AlertLifecycleResponse(
                    AlertPolicyController.AlertPolicyResponse.from(snapshot.policy()), true, lifecycle.state(),
                    AlertPolicyController.AlertEvaluationResponse.from(lifecycle.latestEvaluation()),
                    lifecycle.activeEvidence() == null
                            ? null : AlertPolicyController.AlertEvidenceResponse.from(lifecycle.activeEvidence()),
                    text(lifecycle.startedAt()), text(lifecycle.resolvedAt()), text(lifecycle.lastStateChangeAt()),
                    text(lifecycle.lastProcessedAt()), text(lifecycle.lastEvidenceAt()),
                    lifecycle.latestTransition() == null
                            ? null : AlertTransitionResponse.from(lifecycle.latestTransition()));
        }
    }

    public record AlertTransitionResponse(
            String policyId,
            String type,
            AlertLifecycleState previousState,
            AlertLifecycleState currentState,
            String occurredAt,
            AlertPolicyController.AlertEvaluationResponse evaluation) {

        static AlertTransitionResponse from(AlertTransition transition) {
            return new AlertTransitionResponse(
                    transition.policyId(), transition.type().name(), transition.previousState(),
                    transition.currentState(), transition.occurredAt().toString(),
                    AlertPolicyController.AlertEvaluationResponse.from(transition.evaluation()));
        }
    }

    private static String text(java.time.Instant value) {
        return value == null ? null : value.toString();
    }
}
