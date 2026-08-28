package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
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
import org.springframework.test.context.ContextConfiguration;

@JdbcTest
@ContextConfiguration(classes = GeordiApplication.class)
class H2AlertLifecycleRepositoryTest {

    private static final Instant FIRST = Instant.parse("2026-08-27T16:00:00Z");

    @Autowired
    private JdbcTemplate jdbc;

    private H2AlertLifecycleRepository repository;

    @BeforeEach
    void createRepository() {
        repository = new H2AlertLifecycleRepository(jdbc, JsonMapper.builder().findAndAddModules().build());
    }

    @Test
    void roundTripsTheCanonicalAggregateAndUsesVersionedCompareAndSet() {
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
