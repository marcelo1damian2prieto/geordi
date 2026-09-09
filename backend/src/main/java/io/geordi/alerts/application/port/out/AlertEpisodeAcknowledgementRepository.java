package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertEpisodeAcknowledgement;
import io.geordi.alerts.domain.AlertEpisodeId;
import java.time.Instant;
import java.util.Optional;

public interface AlertEpisodeAcknowledgementRepository {
    Result acknowledge(AlertEpisodeId episodeId, String actor, String reason, Instant acknowledgedAt);
    Optional<AlertEpisodeAcknowledgement> findByEpisodeId(AlertEpisodeId episodeId);

    record Result(Status status, AlertEpisodeAcknowledgement acknowledgement) {
        public enum Status { CREATED, REPLAYED, CONFLICT }
    }
}
