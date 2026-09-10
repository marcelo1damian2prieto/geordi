package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.AcknowledgeAlertEpisodeUseCase;
import io.geordi.alerts.application.AlertEpisodeAcknowledgementConflictException;
import io.geordi.alerts.application.AlertEpisodeNotFoundException;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import java.util.Objects;

/** Emits one bounded outcome for each acknowledgement command without command data attributes. */
public final class ObservedAcknowledgeAlertEpisodeUseCase implements AcknowledgeAlertEpisodeUseCase {

    private static final AttributeKey<String> OUTCOME = AttributeKey.stringKey("geordi.alert.acknowledgement.outcome");
    private final AcknowledgeAlertEpisodeUseCase delegate;
    private final LongCounter acknowledgements;

    public ObservedAcknowledgeAlertEpisodeUseCase(AcknowledgeAlertEpisodeUseCase delegate) {
        this(delegate, GlobalOpenTelemetry.getMeter("io.geordi.alerts"));
    }

    ObservedAcknowledgeAlertEpisodeUseCase(AcknowledgeAlertEpisodeUseCase delegate, Meter meter) {
        this.delegate = Objects.requireNonNull(delegate, "acknowledgement delegate must not be null");
        acknowledgements = Objects.requireNonNull(meter, "alert meter must not be null")
                .counterBuilder("geordi.alert.acknowledgements").build();
    }

    @Override
    public AcknowledgementResult acknowledge(AlertEpisodeId episodeId, String actor, String reason) {
        try {
            AcknowledgementResult result = delegate.acknowledge(episodeId, actor, reason);
            record(result.status() == AcknowledgementResult.Status.CREATED ? "created" : "replayed");
            return result;
        } catch (IllegalArgumentException exception) {
            record("invalid");
            throw exception;
        } catch (AlertEpisodeNotFoundException exception) {
            record("not_found");
            throw exception;
        } catch (AlertEpisodeAcknowledgementConflictException exception) {
            record("conflict");
            throw exception;
        } catch (RuntimeException exception) {
            record("failure");
            throw exception;
        }
    }

    private void record(String outcome) {
        acknowledgements.add(1, Attributes.of(OUTCOME, outcome));
    }
}
