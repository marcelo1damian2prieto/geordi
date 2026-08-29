package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.Optional;
import io.geordi.bootstrap.GeordiApplication;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.JdbcTest;
import org.springframework.dao.DataAccessResourceFailureException;
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
        jdbc.execute("DELETE FROM alert_notification_outbox");
        jdbc.execute("DELETE FROM alert_lifecycle_state");
        repository = new H2AlertLifecycleRepository(jdbc, JsonMapper.builder().findAndAddModules().build());
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
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    void rollsBackTheLifecycleUpdateWhenTheOutboxInsertFails() {
        H2AlertLifecycleRepository transactional = transactionalRepository();
        AlertLifecycle firing = lifecycle(AlertEvaluationStatus.CONDITION_MET, FIRST, Optional.empty());
        NotificationDelivery firstDelivery = delivery(firing, FIRST.plusSeconds(1));
        assertThat(transactional.commit(firing, Optional.empty(), Optional.of(firstDelivery))).isTrue();

        AlertLifecycle inactive = lifecycle(
                AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(2), Optional.of(firing));
        NotificationDelivery duplicateId = new NotificationDelivery(
                firstDelivery.id(), inactive.latestTransition(), firstDelivery.destination(),
                firstDelivery.state(), firstDelivery.attempts(), firstDelivery.createdAt(),
                firstDelivery.nextAttemptAt(), null, null, null);

        assertThatThrownBy(() -> transactional.commit(
                        inactive, Optional.of(0L), Optional.of(duplicateId)))
                .isInstanceOf(AlertLifecyclePersistenceException.class);
        assertThat(transactional.findByPolicyId("checkout-burn").orElseThrow())
                .satisfies(stored -> {
                    assertThat(stored.version()).isZero();
                    assertThat(stored.lifecycle()).isEqualTo(firing);
                });
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_notification_outbox", Integer.class)).isEqualTo(1);
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
