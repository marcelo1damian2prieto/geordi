package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertHistoryRepository;
import io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository;
import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertTransitionRecord;
import java.util.List;
import java.util.Objects;

/** Application boundary for read-only durable alert history. */
public final class AlertHistoryQueryService {

    private final AlertHistoryRepository repository;
    private final AlertEpisodeAcknowledgementRepository acknowledgements;

    public AlertHistoryQueryService(AlertHistoryRepository repository) {
        this.repository = Objects.requireNonNull(repository, "alert history repository must not be null");
        this.acknowledgements = repository instanceof AlertEpisodeAcknowledgementRepository a ? a : null;
    }

    public AlertHistoryQueryService(AlertHistoryRepository repository, AlertEpisodeAcknowledgementRepository acknowledgements) {
        this.repository = Objects.requireNonNull(repository, "alert history repository must not be null");
        this.acknowledgements = Objects.requireNonNull(acknowledgements);
    }

    public List<AlertEpisode> findEpisodes(AlertEpisodeHistoryQuery query) {
        return repository.findEpisodes(Objects.requireNonNull(query, "episode query must not be null"));
    }

    public AlertEpisodeDetail findEpisode(AlertEpisodeId episodeId) {
        AlertEpisodeId requiredId = Objects.requireNonNull(episodeId, "episode id must not be null");
        AlertEpisode episode = repository.findEpisodeById(requiredId).orElseThrow(AlertEpisodeNotFoundException::new);
        List<AlertTransitionRecord> transitions = repository.findTransitions(
                new AlertTransitionHistoryQuery(null, requiredId, null, null, 2));
        return new AlertEpisodeDetail(episode,
                acknowledgements == null ? null : acknowledgements.findByEpisodeId(requiredId).orElse(null), transitions);
    }

    public List<AlertTransitionRecord> findTransitions(AlertTransitionHistoryQuery query) {
        return repository.findTransitions(Objects.requireNonNull(query, "transition query must not be null"));
    }
}
