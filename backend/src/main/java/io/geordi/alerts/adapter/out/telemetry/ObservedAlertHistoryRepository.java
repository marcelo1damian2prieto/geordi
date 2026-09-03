package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.AlertHistoryPersistenceException;
import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertHistoryRepository;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.domain.AlertHistoryMutation;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.geordi.alerts.domain.NotificationDelivery;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;
import java.util.function.Supplier;

/** Observes durable history only at the repository boundary that knows an M14 operation occurred. */
public final class ObservedAlertHistoryRepository implements AlertLifecycleRepository, AlertHistoryRepository {

    private static final AttributeKey<String> OUTCOME =
            AttributeKey.stringKey("geordi.alert.history.outcome");
    private static final AttributeKey<String> TRANSITION_TYPE =
            AttributeKey.stringKey("geordi.alert.history.transition.type");
    private static final AttributeKey<String> QUERY_OPERATION =
            AttributeKey.stringKey("geordi.alert.history.query.operation");

    private final AlertLifecycleRepository lifecycleDelegate;
    private final AlertHistoryRepository historyDelegate;
    private final LongCounter episodes;
    private final LongCounter persistence;
    private final LongCounter queries;

    public ObservedAlertHistoryRepository(
            AlertLifecycleRepository lifecycleDelegate, AlertHistoryRepository historyDelegate) {
        this(lifecycleDelegate, historyDelegate, GlobalOpenTelemetry.getMeter("io.geordi.alerts"));
    }

    ObservedAlertHistoryRepository(
            AlertLifecycleRepository lifecycleDelegate, AlertHistoryRepository historyDelegate, Meter meter) {
        this.lifecycleDelegate = Objects.requireNonNull(
                lifecycleDelegate, "alert lifecycle repository delegate must not be null");
        this.historyDelegate = Objects.requireNonNull(
                historyDelegate, "alert history repository delegate must not be null");
        Objects.requireNonNull(meter, "alert history meter must not be null");
        episodes = meter.counterBuilder("geordi.alert.history.episodes").build();
        persistence = meter.counterBuilder("geordi.alert.history.persistence").build();
        queries = meter.counterBuilder("geordi.alert.history.queries").build();
    }

    @Override
    public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
        return lifecycleDelegate.findByPolicyId(policyId);
    }

    @Override
    public List<VersionedAlertLifecycle> findAll() {
        return lifecycleDelegate.findAll();
    }

    @Override
    public boolean insertIfAbsent(AlertLifecycle lifecycle) {
        return lifecycleDelegate.insertIfAbsent(lifecycle);
    }

    @Override
    public boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion) {
        return lifecycleDelegate.replaceIfVersionMatches(lifecycle, expectedVersion);
    }

    @Override
    public boolean commit(
            AlertLifecycle lifecycle,
            Optional<Long> expectedVersion,
            Optional<NotificationDelivery> delivery) {
        return lifecycleDelegate.commit(lifecycle, expectedVersion, delivery);
    }

    @Override
    public boolean commit(
            AlertLifecycle lifecycle,
            Optional<Long> expectedVersion,
            Optional<NotificationDelivery> delivery,
            Optional<AlertHistoryMutation> historyMutation) {
        Objects.requireNonNull(historyMutation, "alert history mutation must not be null");
        if (historyMutation.isEmpty()) {
            return lifecycleDelegate.commit(lifecycle, expectedVersion, delivery, historyMutation);
        }
        AlertHistoryMutation mutation = historyMutation.orElseThrow();
        boolean committed;
        try {
            committed = lifecycleDelegate.commit(lifecycle, expectedVersion, delivery, historyMutation);
        } catch (AlertHistoryPersistenceException exception) {
            persistence.add(1, Attributes.of(OUTCOME, lower(exception.kind().name())));
            throw exception;
        }
        if (committed) {
            Attributes transition = Attributes.of(
                    TRANSITION_TYPE, lower(mutation.transition().type().name()));
            episodes.add(1, transition);
            persistence.add(1, Attributes.of(OUTCOME, "success"));
        }
        return committed;
    }

    @Override
    public Optional<AlertEpisode> findEpisodeById(AlertEpisodeId episodeId) {
        return observeQuery("episode_by_id", () -> historyDelegate.findEpisodeById(episodeId));
    }

    @Override
    public List<AlertEpisode> findEpisodes(AlertEpisodeHistoryQuery query) {
        return observeQuery("episodes", () -> historyDelegate.findEpisodes(query));
    }

    @Override
    public List<AlertTransitionRecord> findTransitions(AlertTransitionHistoryQuery query) {
        return observeQuery("transitions", () -> historyDelegate.findTransitions(query));
    }

    private <T> T observeQuery(String operation, Supplier<T> query) {
        try {
            T result = query.get();
            queries.add(1, queryAttributes(operation, "success"));
            return result;
        } catch (RuntimeException exception) {
            queries.add(1, queryAttributes(operation, "failure"));
            throw exception;
        }
    }

    private static Attributes queryAttributes(String operation, String outcome) {
        return Attributes.of(QUERY_OPERATION, operation, OUTCOME, outcome);
    }

    private static String lower(String value) {
        return value.toLowerCase(Locale.ROOT);
    }
}
