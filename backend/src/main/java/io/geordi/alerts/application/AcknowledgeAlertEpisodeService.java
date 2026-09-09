package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository;
import io.geordi.alerts.domain.AlertEpisodeId;
import java.time.Clock;
import java.util.Objects;

public final class AcknowledgeAlertEpisodeService implements AcknowledgeAlertEpisodeUseCase {
    private final AlertEpisodeAcknowledgementRepository repository;
    private final Clock clock;

    public AcknowledgeAlertEpisodeService(AlertEpisodeAcknowledgementRepository repository, Clock clock) {
        this.repository = Objects.requireNonNull(repository);
        this.clock = Objects.requireNonNull(clock);
    }

    @Override
    public AcknowledgementResult acknowledge(AlertEpisodeId episodeId, String actor, String reason) {
        Objects.requireNonNull(episodeId, "episode id must not be null");
        String normalizedActor = actor == null ? null : actor.strip();
        String normalizedReason = reason == null ? null : reason.strip();
        if (normalizedReason != null && normalizedReason.isEmpty()) normalizedReason = null;
        if (normalizedActor == null || normalizedActor.isEmpty()
                || normalizedActor.codePointCount(0, normalizedActor.length()) > 128
                || normalizedReason != null && normalizedReason.codePointCount(0, normalizedReason.length()) > 512) {
            throw new IllegalArgumentException("invalid acknowledgement input");
        }
        var result = repository.acknowledge(episodeId, normalizedActor, normalizedReason, clock.instant());
        return new AcknowledgementResult(
                AcknowledgementResult.Status.valueOf(result.status().name()), result.acknowledgement());
    }
}
