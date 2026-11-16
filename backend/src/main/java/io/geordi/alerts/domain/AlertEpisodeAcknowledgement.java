package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Objects;

public record AlertEpisodeAcknowledgement(AlertEpisodeId episodeId, String actor, String reason, Instant acknowledgedAt,
        AlertAcknowledgementAttribution attribution) {
    public AlertEpisodeAcknowledgement(AlertEpisodeId episodeId, String actor, String reason, Instant acknowledgedAt) {
        this(episodeId, actor, reason, acknowledgedAt, AlertAcknowledgementAttribution.legacy());
    }

    public AlertEpisodeAcknowledgement {
        Objects.requireNonNull(episodeId, "episode id must not be null");
        Objects.requireNonNull(attribution, "attribution required");
        boolean authenticated = attribution.provenance()
                == AlertAcknowledgementAttribution.Provenance.AUTHENTICATED_PRINCIPAL;
        if (actor == null || (!authenticated && actor.isBlank()) || actor.codePointCount(0, actor.length()) > 128
                || authenticated && !actor.equals(attribution.actor())) {
            throw new IllegalArgumentException("actor must contain 1 to 128 code points");
        }
        if (reason != null && reason.codePointCount(0, reason.length()) > 512) {
            throw new IllegalArgumentException("reason must contain at most 512 code points");
        }
        Objects.requireNonNull(acknowledgedAt, "acknowledgedAt must not be null");
    }
}
