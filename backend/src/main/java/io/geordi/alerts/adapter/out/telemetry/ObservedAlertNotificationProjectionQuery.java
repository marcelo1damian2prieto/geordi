package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.AlertEpisodeTransition;
import io.geordi.alerts.application.AlertHistoryPersistenceException;
import io.geordi.alerts.application.AlertNotificationIntegrityException;
import io.geordi.alerts.application.AlertNotificationProjectionQuery;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import java.util.List;
import java.util.Locale;
import java.util.Objects;

/** Observes the complete bounded evidence query and projection, including integrity validation. */
public final class ObservedAlertNotificationProjectionQuery implements AlertNotificationProjectionQuery {

    private static final AttributeKey<String> OUTCOME =
            AttributeKey.stringKey("geordi.alert.notification.outcome");
    private static final AttributeKey<String> INTEGRITY_REASON =
            AttributeKey.stringKey("geordi.alert.notification.integrity.reason");

    private final AlertNotificationProjectionQuery delegate;
    private final LongCounter projections;
    private final LongCounter integrityFailures;

    public ObservedAlertNotificationProjectionQuery(AlertNotificationProjectionQuery delegate) {
        this(delegate, GlobalOpenTelemetry.getMeter("io.geordi.alerts"));
    }

    ObservedAlertNotificationProjectionQuery(AlertNotificationProjectionQuery delegate, Meter meter) {
        this.delegate = Objects.requireNonNull(delegate, "notification projection delegate must not be null");
        Objects.requireNonNull(meter, "notification projection meter must not be null");
        projections = meter.counterBuilder("geordi.alert.notification.projections").build();
        integrityFailures = meter.counterBuilder("geordi.alert.notification.integrity.failures").build();
    }

    @Override
    public List<AlertEpisodeTransition> project(List<AlertTransitionRecord> transitions) {
        try {
            List<AlertEpisodeTransition> result = delegate.project(transitions);
            projections.add(1, Attributes.of(OUTCOME, "success"));
            return result;
        } catch (AlertNotificationIntegrityException exception) {
            projections.add(1, Attributes.of(OUTCOME, "invariant_failure"));
            integrityFailures.add(1, Attributes.of(INTEGRITY_REASON,
                    exception.reason().name().toLowerCase(Locale.ROOT)));
            throw exception;
        } catch (AlertHistoryPersistenceException exception) {
            projections.add(1, Attributes.of(OUTCOME,
                    exception.kind() == AlertHistoryPersistenceException.Kind.INVARIANT
                            ? "invariant_failure" : "persistence_failure"));
            throw exception;
        }
    }
}
