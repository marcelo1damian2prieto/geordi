package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.application.AlertHistoryPersistenceException;
import io.geordi.alerts.application.AlertEpisodeAcknowledgementConflictException;
import io.geordi.alerts.application.AlertHistoryPersistenceException.Kind;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.application.port.out.AlertEpisodeHistoryQuery;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEpisodeOrigin;
import io.geordi.alerts.domain.AlertEpisode;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.AlertHistoryMutation;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.bootstrap.GeordiApplication;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.JdbcTest;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

@JdbcTest
@ContextConfiguration(classes = GeordiApplication.class)
class H2AlertLifecycleRepositoryTest {

    private static final Instant FIRST = Instant.parse("2026-08-27T16:00:00Z");

    @Autowired
    private JdbcTemplate jdbc;

    private H2AlertLifecycleRepository repository;

    @BeforeEach
    void createRepository() {
        jdbc.execute("DELETE FROM alert_episode_acknowledgement");
        jdbc.execute("DELETE FROM alert_transition_history");
        jdbc.execute("DELETE FROM alert_episode");
        jdbc.execute("DELETE FROM alert_notification_outbox");
        jdbc.execute("DELETE FROM alert_lifecycle_state");
        repository = new H2AlertLifecycleRepository(jdbc, JsonMapper.builder().findAndAddModules().build(),
                new TransactionTemplate(new JdbcTransactionManager(jdbc.getDataSource())));
    }

    @Test
    void createsAndReplaysAnAcknowledgementWithoutChangingHistory() {
        AlertEpisode episode = AlertEpisode.opened("checkout-burn", FIRST);
        jdbc.update("INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin) VALUES (?, ?, ?, ?, ?)",
                episode.id().value(), episode.policyId(), Timestamp.from(FIRST), null, "M14");
        Instant acknowledged = Instant.parse("2026-08-27T16:00:00.123456789Z");
        var created = repository.acknowledge(episode.id(), "operator", null, acknowledged);
        var replay = repository.acknowledge(episode.id(), "operator", null, acknowledged.plusSeconds(1));
        assertThat(created.status()).isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.CREATED);
        assertThat(replay.status()).isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.REPLAYED);
        assertThat(replay.acknowledgement().acknowledgedAt()).isEqualTo(acknowledged);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode_acknowledgement", Integer.class)).isOne();
    }

    @Test
    void rejectsClosedEpisodeAndPreservesNanoseconds() {
        AlertEpisode episode = AlertEpisode.opened("closed", FIRST).resolve(FIRST.plusSeconds(1));
        jdbc.update("INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin) VALUES (?, ?, ?, ?, ?)",
                episode.id().value(), episode.policyId(), Timestamp.from(FIRST), Timestamp.from(episode.closedAt()), "M14");
        assertThatThrownBy(() -> repository.acknowledge(episode.id(), "operator", null, FIRST))
                .isInstanceOf(AlertEpisodeAcknowledgementConflictException.class);
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void acknowledgementWinsTheEpisodeRowLockBeforeCanonicalResolution() throws Exception {
        var setup = openEpisode();
        var observer = new BlockingLockObserver(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
        H2AlertLifecycleRepository concurrent = transactionalRepository(observer);
        try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
            Future<AlertEpisodeAcknowledgementRepository.Result> acknowledgement = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator", "reason", FIRST.plusSeconds(2)));
            observer.awaitLocked();
            Future<Boolean> resolution = executor.submit(() -> concurrent.commit(
                    setup.inactive(), Optional.of(0L), Optional.empty(),
                    Optional.of(AlertHistoryMutation.from(setup.inactive().latestTransition()))));
            observer.awaitEntered(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.RESOLVE);
            assertThat(resolution.isDone()).isFalse();
            observer.release();
            assertThat(acknowledgement.get(5, TimeUnit.SECONDS).status())
                    .isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.CREATED);
            assertThat(resolution.get(5, TimeUnit.SECONDS)).isTrue();
        }
        assertThat(concurrentEpisode(setup.episode().id()).open()).isFalse();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode_acknowledgement", Integer.class)).isOne();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(2);
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void canonicalResolutionWinsTheEpisodeRowLockBeforeAcknowledgement() throws Exception {
        var setup = openEpisode();
        var observer = new BlockingLockObserver(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.RESOLVE);
        H2AlertLifecycleRepository concurrent = transactionalRepository(observer);
        try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
            Future<Boolean> resolution = executor.submit(() -> concurrent.commit(
                    setup.inactive(), Optional.of(0L), Optional.empty(),
                    Optional.of(AlertHistoryMutation.from(setup.inactive().latestTransition()))));
            observer.awaitLocked();
            Future<AlertEpisodeAcknowledgementRepository.Result> acknowledgement = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator", null, FIRST.plusSeconds(2)));
            observer.awaitEntered(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
            assertThat(acknowledgement.isDone()).isFalse();
            observer.release();
            assertThat(resolution.get(5, TimeUnit.SECONDS)).isTrue();
            assertThatThrownBy(() -> acknowledgement.get(5, TimeUnit.SECONDS))
                    .hasCauseInstanceOf(AlertEpisodeAcknowledgementConflictException.class);
        }
        assertThat(concurrentEpisode(setup.episode().id()).open()).isFalse();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode_acknowledgement", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(2);
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void concurrentIdenticalAcknowledgementsCreateThenReplayTheOriginalValue() throws Exception {
        var setup = openEpisode();
        var observer = new BlockingLockObserver(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
        H2AlertLifecycleRepository concurrent = transactionalRepository(observer);
        try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
            Future<AlertEpisodeAcknowledgementRepository.Result> first = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator", "reason", FIRST.plusSeconds(2)));
            observer.awaitLocked();
            Future<AlertEpisodeAcknowledgementRepository.Result> second = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator", "reason", FIRST.plusSeconds(3)));
            observer.awaitEntered(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
            observer.release();
            var firstResult = first.get(5, TimeUnit.SECONDS);
            var secondResult = second.get(5, TimeUnit.SECONDS);
            assertThat(firstResult.status()).isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.CREATED);
            assertThat(secondResult.status()).isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.REPLAYED);
            assertThat(secondResult.acknowledgement()).isEqualTo(firstResult.acknowledgement());
        }
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode_acknowledgement", Integer.class)).isOne();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isZero();
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void concurrentConflictingAcknowledgementsPreserveTheFirstValue() throws Exception {
        var setup = openEpisode();
        var observer = new BlockingLockObserver(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
        H2AlertLifecycleRepository concurrent = transactionalRepository(observer);
        try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
            Future<AlertEpisodeAcknowledgementRepository.Result> first = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator-a", null, FIRST.plusSeconds(2)));
            observer.awaitLocked();
            Future<AlertEpisodeAcknowledgementRepository.Result> second = executor.submit(
                    () -> concurrent.acknowledge(setup.episode().id(), "operator-b", null, FIRST.plusSeconds(3)));
            observer.awaitEntered(H2AlertLifecycleRepository.EpisodeLockObserver.Operation.ACKNOWLEDGE);
            observer.release();
            assertThat(first.get(5, TimeUnit.SECONDS).status())
                    .isEqualTo(AlertEpisodeAcknowledgementRepository.Result.Status.CREATED);
            assertThatThrownBy(() -> second.get(5, TimeUnit.SECONDS))
                    .hasCauseInstanceOf(AlertEpisodeAcknowledgementConflictException.class);
        }
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode_acknowledgement", Integer.class)).isOne();
        assertThat(jdbc.queryForObject("SELECT actor FROM alert_episode_acknowledgement", String.class)).isEqualTo("operator-a");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isZero();
    }

    @Test
    void roundTripsTheCanonicalAggregateAndUsesVersionedCompareAndSet() {
        assertThat(repository.isAvailable()).isTrue();

        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());

        assertThat(repository.insertIfAbsent(firing)).isTrue();
        assertThat(repository.insertIfAbsent(firing)).isFalse();
        var stored = repository.findByPolicyId("checkout-burn").orElseThrow();
        assertThat(stored.version()).isZero();
        assertThat(stored.lifecycle()).isEqualTo(firing);

        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1), Optional.of(firing));
        assertThat(repository.replaceIfVersionMatches(inactive, 7)).isFalse();
        assertThat(repository.replaceIfVersionMatches(inactive, 0)).isTrue();
        assertThat(repository.findByPolicyId("checkout-burn").orElseThrow())
                .satisfies(value -> {
                    assertThat(value.version()).isEqualTo(1);
                    assertThat(value.lifecycle()).isEqualTo(inactive);
                });
        assertThat(repository.findAll()).hasSize(1);
    }

    @Test
    @SuppressWarnings("unchecked")
    void mapsReadFailuresToTheControlledPersistenceException() {
        JdbcTemplate failingJdbc = mock(JdbcTemplate.class);
        when(failingJdbc.query(anyString(), any(RowMapper.class)))
                .thenThrow(new DataAccessResourceFailureException("database unavailable"));
        H2AlertLifecycleRepository failingRepository = new H2AlertLifecycleRepository(
                failingJdbc, JsonMapper.builder().findAndAddModules().build());

        assertThatThrownBy(failingRepository::findAll)
                .isInstanceOf(AlertLifecyclePersistenceException.class)
                .hasMessage("alert lifecycle persistence operation failed");
    }

    @Test
    @SuppressWarnings("unchecked")
    void mapsHistoryQueryFailuresToTheDedicatedPersistenceException() {
        JdbcTemplate failingJdbc = mock(JdbcTemplate.class);
        when(failingJdbc.query(anyString(), any(RowMapper.class), any(Object[].class)))
                .thenThrow(new DataAccessResourceFailureException("database unavailable"));
        H2AlertLifecycleRepository failingRepository = new H2AlertLifecycleRepository(
                failingJdbc, JsonMapper.builder().findAndAddModules().build());

        assertThatThrownBy(() -> failingRepository.findTransitions(
                        new AlertTransitionHistoryQuery("checkout-burn", null, null, null, 10)))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("alert history persistence operation failed")
                .satisfies(exception -> assertThat(((AlertHistoryPersistenceException) exception).kind())
                        .isEqualTo(Kind.PERSISTENCE));
    }

    @Test
    void reportsPersistenceOutageAndRecoveryWithoutLeakingTheFailure() {
        JdbcTemplate changingJdbc = mock(JdbcTemplate.class);
        when(changingJdbc.queryForObject(anyString(), eq(Integer.class)))
                .thenReturn(0)
                .thenThrow(new DataAccessResourceFailureException("database unavailable"))
                .thenReturn(0);
        H2AlertLifecycleRepository changingRepository = new H2AlertLifecycleRepository(
                changingJdbc, JsonMapper.builder().findAndAddModules().build());

        assertThat(changingRepository.isAvailable()).isTrue();
        assertThat(changingRepository.isAvailable()).isFalse();
        assertThat(changingRepository.isAvailable()).isTrue();
    }

    @Test
    void mapsWriteFailuresToTheControlledPersistenceException() {
        JdbcTemplate failingJdbc = mock(JdbcTemplate.class);
        when(failingJdbc.update(anyString(), any(Object[].class)))
                .thenThrow(new DataAccessResourceFailureException("database unavailable"));
        H2AlertLifecycleRepository failingRepository = new H2AlertLifecycleRepository(
                failingJdbc, JsonMapper.builder().findAndAddModules().build());

        assertThatThrownBy(() -> failingRepository.insertIfAbsent(
                        lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty())))
                .isInstanceOf(AlertLifecyclePersistenceException.class)
                .hasMessage("alert lifecycle persistence operation failed");
    }

    @Test
    void atomicallyPersistsTheWinningLifecycleAndItsNotificationDelivery() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery delivery = delivery(firing, FIRST.plusSeconds(1));

        assertThat(transactional.commit(firing, Optional.empty(), Optional.of(delivery))).isTrue();

        assertThat(transactional.findByPolicyId("checkout-burn").orElseThrow().lifecycle()).isEqualTo(firing);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject(
                        "SELECT delivery_id FROM alert_notification_outbox", String.class))
                .isEqualTo(delivery.id());
    }

    @Test
    void atomicallyTracksAndClosesTheSameNormalEpisodeForCanonicalTransitions() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery startedDelivery = delivery(firing, FIRST);

        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.of(startedDelivery),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();

        var opened = transactional.findEpisodes(new AlertEpisodeHistoryQuery("checkout-burn", null, null, null, 10));
        assertThat(opened).singleElement().satisfies(episode -> {
            assertThat(episode.open()).isTrue();
            assertThat(episode.openedAt()).isEqualTo(FIRST);
            assertThat(episode.origin()).isEqualTo(AlertEpisodeOrigin.M14);
        });

        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1), Optional.of(firing));
        NotificationDelivery resolvedDelivery = delivery(inactive, FIRST.plusSeconds(1));
        assertThat(transactional.commit(
                inactive, Optional.of(0L), Optional.of(resolvedDelivery),
                Optional.of(AlertHistoryMutation.from(inactive.latestTransition())))).isTrue();

        assertThat(transactional.findEpisodes(new AlertEpisodeHistoryQuery("checkout-burn", null, null, null, 10)))
                .singleElement()
                .satisfies(episode -> {
                    assertThat(episode.open()).isFalse();
                    assertThat(episode.closedAt()).isEqualTo(FIRST.plusSeconds(1));
                });
        assertThat(transactional.findTransitions(
                        new AlertTransitionHistoryQuery("checkout-burn", null, null, null, 10)))
                .extracting(record -> record.transition().type())
                .containsExactly(io.geordi.alerts.domain.AlertTransitionType.ALERT_RESOLVED,
                        io.geordi.alerts.domain.AlertTransitionType.ALERT_STARTED);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_lifecycle_state", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(2);
    }

    @Test
    void persistsHistoryWithoutAnOutboxRowWhenDeliveryIsSuppressedOrUnrouted() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());

        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.empty(),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();

        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_lifecycle_state", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isZero();
    }

    @Test
    void createsAnExplicitLegacyEpisodeWhenTheFirstTrackedFactIsAResolution() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.insertIfAbsent(firing)).isTrue();
        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1), Optional.of(firing));
        NotificationDelivery delivery = delivery(inactive, FIRST.plusSeconds(1));

        assertThat(transactional.commit(
                inactive, Optional.of(0L), Optional.of(delivery),
                Optional.of(AlertHistoryMutation.from(inactive.latestTransition())))).isTrue();

        assertThat(transactional.findEpisodes(new AlertEpisodeHistoryQuery("checkout-burn", null, null, null, 10)))
                .singleElement()
                .satisfies(episode -> {
                    assertThat(episode.origin()).isEqualTo(io.geordi.alerts.domain.AlertEpisodeOrigin.PRE_M14_UNKNOWN_START);
                    assertThat(episode.openedAt()).isNull();
                    assertThat(episode.closedAt()).isEqualTo(FIRST.plusSeconds(1));
                });
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT open_policy_id FROM alert_episode", String.class)).isNull();
    }

    @Test
    void databaseRejectsOpenLegacyEpisodesAndTransitionPolicyDrift() {
        assertThatThrownBy(() -> jdbc.update(
                        """
                        INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        "a".repeat(64), "checkout-burn", null, null,
                        AlertEpisodeOrigin.PRE_M14_UNKNOWN_START.name()))
                .isInstanceOf(DataIntegrityViolationException.class);

        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.empty(),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();

        assertThatThrownBy(() -> jdbc.update(
                        "UPDATE alert_transition_history SET policy_id = ?",
                        "different-policy"))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    void rejectsTransitionRowsWhoseRelationalColumnsDriftFromCanonicalJson() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.empty(),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();

        assertTransitionCorruptionRejected(transactional, "transition_type", "ALERT_RESOLVED", "ALERT_STARTED");
        assertTransitionCorruptionRejected(
                transactional, "occurred_at", Timestamp.from(FIRST.plusSeconds(1)), Timestamp.from(FIRST));
        assertTransitionCorruptionRejected(transactional, "previous_state", "FIRING", "INACTIVE");
        assertTransitionCorruptionRejected(transactional, "current_state", "INACTIVE", "FIRING");
        jdbc.update(
                "UPDATE alert_transition_history SET transition_json = REPLACE(transition_json, ?, ?)",
                "checkout-burn", "different-policy");
        assertThatThrownBy(() -> transactional.findTransitions(
                        new AlertTransitionHistoryQuery("checkout-burn", null, null, null, 10)))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("stored alert transition history is invalid")
                .satisfies(exception -> assertThat(((AlertHistoryPersistenceException) exception).kind())
                        .isEqualTo(Kind.INVARIANT));
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void casLossWritesNeitherHistoryNorOutbox() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.insertIfAbsent(firing)).isTrue();

        assertThat(transactional.commit(
                firing, Optional.of(99L), Optional.of(delivery(firing, FIRST)),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isFalse();

        assertThat(transactional.findByPolicyId("checkout-burn").orElseThrow().version()).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isZero();
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void rollsBackLifecycleEpisodeHistoryAndOutboxWhenTheOutboxInsertFails() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery firstDelivery = delivery(firing, FIRST.plusSeconds(1));
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.of(firstDelivery),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();

        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(2), Optional.of(firing));
        NotificationDelivery duplicateId = new NotificationDelivery(
                firstDelivery.id(), inactive.latestTransition(), firstDelivery.destination(),
                firstDelivery.state(), firstDelivery.attempts(), firstDelivery.createdAt(),
                firstDelivery.nextAttemptAt(), null, null, null);

        assertThatThrownBy(() -> transactional.commit(
                        inactive, Optional.of(0L), Optional.of(duplicateId),
                        Optional.of(AlertHistoryMutation.from(inactive.latestTransition()))))
                .isInstanceOf(AlertLifecyclePersistenceException.class);
        assertThat(transactional.findByPolicyId("checkout-burn").orElseThrow())
                .satisfies(stored -> {
                    assertThat(stored.version()).isZero();
                    assertThat(stored.lifecycle()).isEqualTo(firing);
                });
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT closed_at FROM alert_episode", Timestamp.class)).isNull();
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void rollsBackLifecycleAndOutboxWhenHistoryInsertFails() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        AlertHistoryMutation.Opened mutation =
                (AlertHistoryMutation.Opened) AlertHistoryMutation.from(firing.latestTransition());
        jdbc.update(
                """
                INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin)
                VALUES (?, ?, ?, ?, ?)
                """,
                mutation.episode().id().value(), mutation.episode().policyId(), Timestamp.from(FIRST), null, "M14");

        assertThatThrownBy(() -> transactional.commit(
                        firing, Optional.empty(), Optional.of(delivery(firing, FIRST)), Optional.of(mutation)))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("alert history persistence operation failed")
                .satisfies(exception -> assertThat(((AlertHistoryPersistenceException) exception).kind())
                        .isEqualTo(Kind.PERSISTENCE));

        assertThat(transactional.findByPolicyId("checkout-burn")).isEmpty();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isZero();
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void startedHistoryWithoutAnOpenEpisodeFailsClosedInsteadOfCreatingLegacyHistory() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.of(delivery(firing, FIRST)),
                Optional.of(AlertHistoryMutation.from(firing.latestTransition())))).isTrue();
        jdbc.update("UPDATE alert_episode SET closed_at = ?", Timestamp.from(FIRST.plusSeconds(1)));

        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(2), Optional.of(firing));
        assertThatThrownBy(() -> transactional.commit(
                        inactive, Optional.of(0L), Optional.of(delivery(inactive, FIRST.plusSeconds(2))),
                        Optional.of(AlertHistoryMutation.from(inactive.latestTransition()))))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("normal alert resolution has no open episode")
                .satisfies(exception -> assertThat(((AlertHistoryPersistenceException) exception).kind())
                        .isEqualTo(Kind.INVARIANT));

        assertThat(transactional.findByPolicyId("checkout-burn").orElseThrow())
                .satisfies(stored -> {
                    assertThat(stored.version()).isZero();
                    assertThat(stored.lifecycle()).isEqualTo(firing);
                });
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_episode", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM alert_episode WHERE origin = 'PRE_M14_UNKNOWN_START'", Integer.class))
                .isZero();
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void claimsAndFinalizesDeliveryOnlyForTheCurrentLeaseToken() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery delivery = delivery(firing, FIRST);
        assertThat(transactional.commit(firing, Optional.empty(), Optional.of(delivery))).isTrue();

        NotificationDelivery claimed = transactional.claimDue(FIRST, FIRST.plusSeconds(30), 10, 3).getFirst();

        assertThat(claimed.state()).isEqualTo(io.geordi.alerts.domain.NotificationDeliveryState.LEASED);
        assertThat(transactional.markDelivered(claimed.id(), "stale-token", FIRST.plusSeconds(1))).isFalse();
        assertThat(transactional.markDelivered(claimed.id(), claimed.claimToken(), FIRST.plusSeconds(1))).isTrue();
        assertThat(transactional.claimDue(FIRST.plusSeconds(2), FIRST.plusSeconds(32), 10, 3)).isEmpty();
        assertThat(jdbc.queryForObject(
                        "SELECT state || ':' || attempts FROM alert_notification_outbox", String.class))
                .isEqualTo("DELIVERED:1");
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void recoversExpiredLeasesAndOnlyTheWinningLeaseMayRetryOrFail() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery delivery = delivery(firing, FIRST);
        assertThat(transactional.commit(firing, Optional.empty(), Optional.of(delivery))).isTrue();

        NotificationDelivery firstClaim = transactional.claimDue(FIRST, FIRST.plusSeconds(5), 1, 3).getFirst();
        NotificationDelivery recoveredClaim = transactional.claimDue(FIRST.plusSeconds(5), FIRST.plusSeconds(10), 1, 3)
                .getFirst();

        assertThat(recoveredClaim.claimToken()).isNotEqualTo(firstClaim.claimToken());
        assertThat(transactional.reschedule(
                        firstClaim.id(), firstClaim.claimToken(), FIRST.plusSeconds(20)))
                .isFalse();
        assertThat(transactional.reschedule(
                        recoveredClaim.id(), recoveredClaim.claimToken(), FIRST.plusSeconds(20)))
                .isTrue();
        assertThat(transactional.claimDue(FIRST.plusSeconds(19), FIRST.plusSeconds(24), 1, 3)).isEmpty();

        NotificationDelivery retryClaim = transactional.claimDue(
                FIRST.plusSeconds(20), FIRST.plusSeconds(25), 1, 3).getFirst();
        assertThat(transactional.markFailed(retryClaim.id(), retryClaim.claimToken(), FIRST.plusSeconds(21))).isTrue();
        assertThat(transactional.claimDue(FIRST.plusSeconds(30), FIRST.plusSeconds(35), 1, 3)).isEmpty();
        assertThat(jdbc.queryForObject(
                        "SELECT state || ':' || attempts FROM alert_notification_outbox", String.class))
                .isEqualTo("FAILED:3");
    }

    @Test
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void crashAfterTheFinalSendConsumesTheAttemptAndExpiresToFailed() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.of(delivery(firing, FIRST)))).isTrue();

        NotificationDelivery first = transactional.claimDue(FIRST, FIRST.plusSeconds(1), 1, 3).getFirst();
        assertThat(transactional.reschedule(
                first.id(), first.claimToken(), FIRST.plusSeconds(1))).isTrue();
        NotificationDelivery second = transactional.claimDue(
                FIRST.plusSeconds(1), FIRST.plusSeconds(2), 1, 3).getFirst();
        assertThat(transactional.reschedule(
                second.id(), second.claimToken(), FIRST.plusSeconds(2))).isTrue();
        NotificationDelivery finalAttempt = transactional.claimDue(
                FIRST.plusSeconds(2), FIRST.plusSeconds(3), 1, 3).getFirst();

        assertThat(finalAttempt.attempts()).isEqualTo(3);
        assertThat(transactional.claimDue(FIRST.plusSeconds(3), FIRST.plusSeconds(4), 1, 3)).isEmpty();
        assertThat(jdbc.queryForObject(
                        "SELECT state || ':' || attempts FROM alert_notification_outbox", String.class))
                .isEqualTo("FAILED:3");
    }

    private H2AlertLifecycleRepository transactionalRepository() {
        return new H2AlertLifecycleRepository(
                jdbc, JsonMapper.builder().findAndAddModules().build(),
                new TransactionTemplate(new JdbcTransactionManager(jdbc.getDataSource())));
    }

    private H2AlertLifecycleRepository transactionalRepository(H2AlertLifecycleRepository.EpisodeLockObserver observer) {
        return new H2AlertLifecycleRepository(
                jdbc, JsonMapper.builder().findAndAddModules().build(),
                new TransactionTemplate(new JdbcTransactionManager(jdbc.getDataSource())), observer);
    }

    private OpenEpisodeSetup openEpisode() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        assertThat(transactional.commit(
                firing, Optional.empty(), Optional.empty(), Optional.of(AlertHistoryMutation.from(firing.latestTransition()))))
                .isTrue();
        AlertEpisode episode = transactional.findEpisodes(new AlertEpisodeHistoryQuery("checkout-burn", null, null, null, 10))
                .getFirst();
        AlertLifecycle inactive = lifecycle(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1), Optional.of(firing));
        return new OpenEpisodeSetup(episode, inactive);
    }

    private AlertEpisode concurrentEpisode(AlertEpisodeId episodeId) {
        return transactionalRepository().findEpisodeById(episodeId).orElseThrow();
    }

    private record OpenEpisodeSetup(AlertEpisode episode, AlertLifecycle inactive) { }

    private static final class BlockingLockObserver implements H2AlertLifecycleRepository.EpisodeLockObserver {
        private final Operation blockedOperation;
        private final CountDownLatch lockAcquired = new CountDownLatch(1);
        private final CountDownLatch competingEntered = new CountDownLatch(1);
        private final CountDownLatch release = new CountDownLatch(1);
        private final AtomicInteger blockedEntries = new AtomicInteger();

        private BlockingLockObserver(Operation blockedOperation) {
            this.blockedOperation = blockedOperation;
        }

        @Override
        public void beforeLock(Operation operation) {
            if (operation != blockedOperation || blockedEntries.incrementAndGet() > 1) {
                competingEntered.countDown();
            }
        }

        @Override
        public void afterLock(Operation operation) {
            if (operation != blockedOperation || blockedEntries.get() != 1) {
                return;
            }
            lockAcquired.countDown();
            await(release, "winning transaction was not released");
        }

        private void awaitLocked() {
            await(lockAcquired, "winning transaction did not acquire the episode row lock");
        }

        private void awaitEntered(Operation operation) {
            await(competingEntered, "competing " + operation + " did not enter the persistence path");
        }

        private void release() {
            release.countDown();
        }

        private static void await(CountDownLatch latch, String message) {
            try {
                if (!latch.await(5, TimeUnit.SECONDS)) {
                    throw new AssertionError(message);
                }
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                throw new AssertionError(message, exception);
            }
        }
    }

    private void assertTransitionCorruptionRejected(
            H2AlertLifecycleRepository transactional, String column, Object corrupted, Object canonical) {
        jdbc.update("UPDATE alert_transition_history SET " + column + " = ?", corrupted);
        assertThatThrownBy(() -> transactional.findTransitions(
                        new AlertTransitionHistoryQuery("checkout-burn", null, null, null, 10)))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("stored alert transition history is invalid")
                .satisfies(exception -> assertThat(((AlertHistoryPersistenceException) exception).kind())
                        .isEqualTo(Kind.INVARIANT));
        jdbc.update("UPDATE alert_transition_history SET " + column + " = ?", canonical);
    }

    private static NotificationDelivery delivery(AlertLifecycle lifecycle, Instant createdAt) {
        return NotificationDelivery.pending(
                lifecycle.latestTransition(), new NotificationDestination("operations-webhook", "f1a5b7c9"), createdAt);
    }

    private static AlertLifecycle lifecycle(
            AlertEvaluationStatus status, Instant evaluatedAt, Optional<AlertLifecycle> previous) {
        BurnRateEvidence evidence = new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(evaluatedAt.minusSeconds(300), evaluatedAt), evaluatedAt,
                status == AlertEvaluationStatus.CONDITION_MET ? new BigDecimal("3") : new BigDecimal("0.5"), null);
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-burn", "Checkout burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                status, null, evidence);
        return AlertLifecycleTransitions.apply(previous, evaluation, null).current();
    }
}
