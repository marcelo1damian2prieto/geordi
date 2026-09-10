package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertEpisodeAcknowledgement;
import io.geordi.alerts.domain.AlertEpisodeId;

public interface AcknowledgeAlertEpisodeUseCase {
    AcknowledgementResult acknowledge(AlertEpisodeId episodeId, String actor, String reason);

    record AcknowledgementResult(Status status, AlertEpisodeAcknowledgement acknowledgement) {
        public enum Status { CREATED, REPLAYED }
    }
}
