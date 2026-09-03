package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertTransitionRecord;
import java.util.List;
import java.util.Optional;

/**
 * Read-only persistence port for durable alert episode and transition history.
 */
public interface AlertHistoryRepository {

    Optional<AlertEpisode> findEpisodeById(AlertEpisodeId episodeId);

    List<AlertEpisode> findEpisodes(AlertEpisodeHistoryQuery query);

    List<AlertTransitionRecord> findTransitions(AlertTransitionHistoryQuery query);
}
