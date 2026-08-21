package io.geordi.slos.adapter.in.web;

import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.application.SloQueryService;
import io.geordi.slos.domain.BurnRateEvaluation;
import io.geordi.slos.domain.BurnRateStatus;
import io.geordi.slos.domain.BurnRateUnavailableReason;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import io.geordi.slos.domain.SloEvaluation;
import io.geordi.slos.domain.SloStatus;
import io.geordi.slos.domain.UnavailableReason;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnExpression("${geordi.modules.slos.enabled:true} && ${geordi.modules.metrics.enabled:true}")
@RequestMapping("/api/slos")
public class SloController {

    private final SloQueryService queryService;
    private final SloEvaluationUseCase evaluationService;

    public SloController(SloQueryService queryService, SloEvaluationUseCase evaluationService) {
        this.queryService = queryService;
        this.evaluationService = evaluationService;
    }

    @GetMapping
    public SloDefinitionsResponse list() {
        return new SloDefinitionsResponse(queryService.findAll().stream().map(SloDefinitionResponse::from).toList());
    }

    @GetMapping("/{sloId}")
    public SloDefinitionResponse detail(@PathVariable String sloId) {
        return SloDefinitionResponse.from(queryService.findById(sloId));
    }

    @GetMapping("/{sloId}/evaluation")
    public SloEvaluationResponse evaluate(@PathVariable String sloId) {
        return SloEvaluationResponse.from(evaluationService.evaluate(sloId));
    }

    public record SloDefinitionsResponse(List<SloDefinitionResponse> slos) {
    }

    public record SloDefinitionResponse(
            String id,
            String name,
            String description,
            ServiceIdentity service,
            SliType sliType,
            BigDecimal target,
            String window,
            boolean enabled) {

        static SloDefinitionResponse from(SloDefinition definition) {
            return new SloDefinitionResponse(
                    definition.id(), definition.name(), definition.description(), definition.service(),
                    definition.sliType(), definition.target(), definition.window().value(), definition.enabled());
        }
    }

    public record SloEvaluationResponse(
            String sloId,
            ServiceIdentity service,
            SliType sliType,
            BigDecimal target,
            String window,
            RangeResponse range,
            String evaluatedAt,
            BigDecimal observedValue,
            BigDecimal requestCount,
            SloStatus status,
            UnavailableReason reason,
            BurnRateEvaluationResponse burnRateEvaluation) {

        static SloEvaluationResponse from(SloEvaluation evaluation) {
            return new SloEvaluationResponse(
                    evaluation.sloId(), evaluation.service(), evaluation.sliType(), evaluation.target(),
                    evaluation.window().value(),
                    new RangeResponse(evaluation.range().from().toString(), evaluation.range().to().toString()),
                    evaluation.evaluatedAt().toString(), evaluation.observedValue(), evaluation.requestCount(),
                    evaluation.status(), evaluation.reason(),
                    BurnRateEvaluationResponse.from(evaluation.burnRateEvaluation()));
        }
    }

    public record BurnRateEvaluationResponse(
            BigDecimal allowedBadRatio,
            BigDecimal observedBadRatio,
            BigDecimal burnRate,
            BurnRateStatus status,
            BurnRateUnavailableReason reason) {

        static BurnRateEvaluationResponse from(BurnRateEvaluation evaluation) {
            return new BurnRateEvaluationResponse(
                    evaluation.allowedBadRatio(), evaluation.observedBadRatio(), evaluation.burnRate(),
                    evaluation.status(), evaluation.reason());
        }
    }

    public record RangeResponse(String from, String to) {
    }
}
