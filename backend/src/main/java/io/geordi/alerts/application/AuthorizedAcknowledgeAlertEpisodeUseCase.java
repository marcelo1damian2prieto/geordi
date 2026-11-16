package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertAcknowledgementAttribution;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PermissionCheck;
import java.util.Objects;

/** Authenticated HTTP mutation boundary; caller-supplied actor assertions are not accepted. */
public final class AuthorizedAcknowledgeAlertEpisodeUseCase implements AuthorizedAcknowledgeAlertEpisode {
    private final AcknowledgeAlertEpisodeService acknowledgements;

    public AuthorizedAcknowledgeAlertEpisodeUseCase(AcknowledgeAlertEpisodeService acknowledgements) {
        this.acknowledgements = Objects.requireNonNull(acknowledgements);
    }

    @Override
    public AcknowledgeAlertEpisodeUseCase.AcknowledgementResult acknowledge(
            AuthenticatedPrincipal principal, AlertEpisodeId episodeId,
            String reason) {
        PermissionCheck.require(principal, GeordiPermission.ALERT_ACKNOWLEDGE);
        var identity = principal.identity();
        var attribution = AlertAcknowledgementAttribution.authenticated(identity.issuer(), identity.subject(),
                principal.displayName());
        return acknowledgements.acknowledgeAuthenticated(episodeId, attribution, reason);
    }
}
