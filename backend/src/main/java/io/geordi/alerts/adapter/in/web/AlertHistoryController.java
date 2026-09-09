package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertEpisodeDetail;
import io.geordi.alerts.application.AlertHistoryQueryService;
import io.geordi.alerts.application.AcknowledgeAlertEpisodeUseCase;
import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertEpisodeState;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertEpisodeOrigin;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionRecord;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.beans.factory.annotation.Autowired;

/** HTTP adapter for the bounded, read-only durable alert-history projection. */
@RestController
@ConditionalOnExpression(
        "${geordi.modules.alerts.enabled:true} && ${geordi.modules.slos.enabled:true}"
                + " && ${geordi.modules.metrics.enabled:true}")
@RequestMapping("/api")
public class AlertHistoryController {

    private final AlertHistoryQueryService queries;
    private final AcknowledgeAlertEpisodeUseCase acknowledgements;

    @Autowired
    public AlertHistoryController(AlertHistoryQueryService queries, AcknowledgeAlertEpisodeUseCase acknowledgements) {
        this.queries = queries;
        this.acknowledgements = acknowledgements;
    }

    public AlertHistoryController(AlertHistoryQueryService queries) {
        this(queries, (episodeId, actor, reason) -> { throw new UnsupportedOperationException(); });
    }

    @GetMapping("/alert-episodes")
    public AlertEpisodesResponse listEpisodes(
            @RequestParam(required = false) String policyId,
            @RequestParam(required = false) String state,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false) Integer limit) {
        AlertEpisodeHistoryQuery query = new AlertEpisodeHistoryQuery(
                policyId, parseEpisodeState(state), parseInstant(from), parseInstant(to),
                limit == null ? 50 : limit);
        return new AlertEpisodesResponse(queries.findEpisodes(query).stream()
                .map(AlertEpisodeResponse::from)
                .toList());
    }

    @GetMapping("/alert-episodes/{episodeId}")
    public AlertEpisodeDetailResponse detail(@PathVariable String episodeId) {
        return AlertEpisodeDetailResponse.from(queries.findEpisode(new AlertEpisodeId(episodeId)));
    }

    @PostMapping("/alert-episodes/{episodeId}/acknowledgements")
    public ResponseEntity<AlertAcknowledgementResponse> acknowledge(
            @PathVariable String episodeId, @RequestBody AlertAcknowledgementRequest request) {
        var result = acknowledgements.acknowledge(new AlertEpisodeId(episodeId), request.actor(), request.reason());
        HttpStatus status = result.status() == AcknowledgeAlertEpisodeUseCase.AcknowledgementResult.Status.CREATED
                ? HttpStatus.CREATED : HttpStatus.OK;
        return ResponseEntity.status(status).body(AlertAcknowledgementResponse.from(result.acknowledgement()));
    }

    public record AlertAcknowledgementRequest(String actor, String reason) { }

    public record AlertAcknowledgementResponse(String actor, String reason, String acknowledgedAt) {
        static AlertAcknowledgementResponse from(io.geordi.alerts.domain.AlertEpisodeAcknowledgement value) {
            return new AlertAcknowledgementResponse(value.actor(), value.reason(), value.acknowledgedAt().toString());
        }
    }

    @GetMapping("/alert-transitions")
    public AlertTransitionsResponse listTransitions(
            @RequestParam(required = false) String policyId,
            @RequestParam(required = false) String episodeId,
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            @RequestParam(required = false) Integer limit) {
        AlertTransitionHistoryQuery query = new AlertTransitionHistoryQuery(
                policyId, episodeId == null ? null : new AlertEpisodeId(episodeId),
                parseInstant(from), parseInstant(to),
                limit == null ? 100 : limit);
        return new AlertTransitionsResponse(queries.findTransitions(query).stream()
                .map(AlertTransitionHistoryResponse::from)
                .toList());
    }

    public record AlertEpisodesResponse(List<AlertEpisodeResponse> alertEpisodes) {
    }

    public record AlertEpisodeDetailResponse(
            AlertEpisodeResponse episode, AlertAcknowledgementResponse acknowledgement,
            List<AlertTransitionHistoryResponse> transitions) {

        static AlertEpisodeDetailResponse from(AlertEpisodeDetail detail) {
            return new AlertEpisodeDetailResponse(
                    AlertEpisodeResponse.from(detail.episode()), detail.acknowledgement() == null ? null : AlertAcknowledgementResponse.from(detail.acknowledgement()),
                    detail.transitions().stream().map(AlertTransitionHistoryResponse::from).toList());
        }
    }

    public record AlertEpisodeResponse(
            String id,
            String policyId,
            String openedAt,
            String closedAt,
            AlertEpisodeOrigin origin,
            Long durationSeconds) {

        static AlertEpisodeResponse from(AlertEpisode episode) {
            return new AlertEpisodeResponse(
                    episode.id().value(), episode.policyId(), text(episode.openedAt()), text(episode.closedAt()),
                    episode.origin(), AlertHistoryController.durationSeconds(episode));
        }
    }

    public record AlertTransitionsResponse(List<AlertTransitionHistoryResponse> alertTransitions) {
    }

    public record AlertTransitionHistoryResponse(
            String id,
            String episodeId,
            String policyId,
            String type,
            AlertLifecycleState previousState,
            AlertLifecycleState currentState,
            String occurredAt,
            AlertPolicyController.AlertEvaluationResponse evaluation) {

        static AlertTransitionHistoryResponse from(AlertTransitionRecord record) {
            AlertTransition transition = record.transition();
            return new AlertTransitionHistoryResponse(
                    record.id().value(), record.episodeId().value(), transition.policyId(), transition.type().name(),
                    transition.previousState(), transition.currentState(), transition.occurredAt().toString(),
                    AlertPolicyController.AlertEvaluationResponse.from(transition.evaluation()));
        }
    }

    private static AlertEpisodeState parseEpisodeState(String state) {
        if (state == null) {
            return null;
        }
        return AlertEpisodeState.valueOf(state);
    }

    private static Instant parseInstant(String text) {
        return text == null ? null : Instant.parse(text);
    }

    private static String text(Instant value) {
        return value == null ? null : value.toString();
    }

    private static Long durationSeconds(AlertEpisode episode) {
        return episode.openedAt() == null || episode.closedAt() == null
                ? null
                : Duration.between(episode.openedAt(), episode.closedAt()).toSeconds();
    }
}
