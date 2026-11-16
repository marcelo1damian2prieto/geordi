package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.core.application.security.AuthenticatedPrincipal;

/** Permission-checked application entry for HTTP acknowledgements. */
@FunctionalInterface
public interface AuthorizedAcknowledgeAlertEpisode {
    AcknowledgeAlertEpisodeUseCase.AcknowledgementResult acknowledge(
            AuthenticatedPrincipal principal, AlertEpisodeId episodeId, String reason);
}
