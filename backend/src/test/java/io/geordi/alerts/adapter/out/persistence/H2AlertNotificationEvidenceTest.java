package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.application.AlertNotificationIntegrityException;
import io.geordi.alerts.application.AlertNotificationProjectionService;
import io.geordi.alerts.application.AlertNotificationStatus;
import io.geordi.alerts.domain.*;
import io.geordi.bootstrap.GeordiApplication;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.JdbcTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.transaction.support.TransactionTemplate;

@JdbcTest
@ContextConfiguration(classes = GeordiApplication.class)
class H2AlertNotificationEvidenceTest {
    @Autowired
    private JdbcTemplate jdbc;

    @ParameterizedTest
    @ValueSource(strings = {"2026-08-28T18:00:00.123456789Z", "2026-08-28T18:00:00.999999999Z"})
    void legacyCorrelationUsesCanonicalPayloadAcrossSqlTimestampRounding(String time) {
        Fixture fixture = matched(Instant.parse(time));
        jdbc.update("DELETE FROM alert_notification_disposition WHERE transition_id = ?", fixture.record().id().value());
        var status = fixture.project();
        assertThat(status.disposition()).isEqualTo(AlertNotificationStatus.Disposition.NOT_RECORDED);
        assertThat(status.delivery().state()).isEqualTo(NotificationDeliveryState.PENDING);
        assertThat(jdbc.queryForObject("SELECT occurred_at FROM alert_notification_outbox WHERE delivery_id = ?",
                java.sql.Timestamp.class, fixture.record().id().value()).toInstant())
                .isNotEqualTo(fixture.record().transition().occurredAt());
        jdbc.update("DELETE FROM alert_notification_outbox WHERE delivery_id = ?", fixture.record().id().value());
        assertThat(fixture.project().delivery()).isNull();
    }

    @Test
    void sameIdLegacyPayloadMismatchFailsInsteadOfHidingDelivery() throws Exception {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        jdbc.update("DELETE FROM alert_notification_disposition WHERE transition_id = ?", fixture.record().id().value());
        String changed = JsonMapper.builder().findAndAddModules().build().writeValueAsString(
                lifecycle(Instant.parse("2026-08-28T18:00:01Z")).latestTransition());
        jdbc.update("UPDATE alert_notification_outbox SET payload_json = ? WHERE delivery_id = ?", changed,
                fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.CORRELATION_INVALID));
    }

    @ParameterizedTest
    @ValueSource(strings = {"malformed", "null", "{}"})
    void malformedCanonicalPayloadFailsAsBoundedInvariant(String payload) {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        jdbc.update("UPDATE alert_notification_outbox SET payload_json = ? WHERE delivery_id = ?", payload,
                fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOf(AlertNotificationIntegrityException.class);
    }

    @ParameterizedTest
    @ValueSource(strings = {"UNKNOWN", "pending", ""})
    void malformedDeliveryStateFailsAsBoundedInvariant(String state) {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        jdbc.update("UPDATE alert_notification_outbox SET state = ? WHERE delivery_id = ?", state, fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID));
    }

    @Test
    void requiredCompletionTimeAndAttemptsAreValidated() {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        jdbc.update("UPDATE alert_notification_outbox SET state = 'DELIVERED' WHERE delivery_id = ?", fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOf(AlertNotificationIntegrityException.class);
        jdbc.update("UPDATE alert_notification_outbox SET state = 'PENDING', attempts = -1 WHERE delivery_id = ?", fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOf(AlertNotificationIntegrityException.class);
    }

    @ParameterizedTest
    @ValueSource(strings = {"NULL", "NOT_RECORDED", "unknown", "matched"})
    void malformedPersistedDispositionCannotBecomeAbsentEvidence(String value) throws Exception {
        var row = org.mockito.Mockito.mock(java.sql.ResultSet.class);
        var id = AlertTransitionId.from(lifecycle(Instant.parse("2026-08-28T18:00:00Z")).latestTransition());
        org.mockito.Mockito.when(row.getString("transition_id")).thenReturn(id.value());
        org.mockito.Mockito.when(row.getString("disposition_transition_id")).thenReturn(id.value());
        org.mockito.Mockito.when(row.getString("disposition")).thenReturn(value.equals("NULL") ? null : value);
        var queryJdbc = org.mockito.Mockito.mock(JdbcTemplate.class);
        org.mockito.Mockito.doAnswer(call -> {
            org.springframework.jdbc.core.RowMapper<?> mapper = call.getArgument(1);
            return List.of(mapper.mapRow(row, 0));
        }).when(queryJdbc).query(org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class),
                org.mockito.ArgumentMatchers.any(Object[].class));
        var repository = new H2AlertLifecycleRepository(queryJdbc, JsonMapper.builder().findAndAddModules().build());
        assertThatThrownBy(() -> repository.findNotificationEvidence(List.of(id)))
                .isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                        failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID));
    }

    @Test
    void rejectsDurableDispositionAndDeliveryContradictions() {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        for (String disposition : List.of("SUPPRESSED", "UNROUTED")) {
            jdbc.update("UPDATE alert_notification_disposition SET disposition = ? WHERE transition_id = ?",
                    disposition, fixture.record().id().value());
            assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                    failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.UNEXPECTED_DELIVERY));
        }
        jdbc.update("UPDATE alert_notification_disposition SET disposition = 'MATCHED' WHERE transition_id = ?", fixture.record().id().value());
        jdbc.update("DELETE FROM alert_notification_outbox WHERE delivery_id = ?", fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.MATCHED_DELIVERY_MISSING));
    }

    @ParameterizedTest
    @ValueSource(strings = {"LEASED", "PENDING", "DELIVERED", "FAILED"})
    void rejectsCorruptLeaseOwnershipAndReturnsSanitized503(String state) throws Exception {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        jdbc.update("UPDATE alert_notification_outbox SET state = ?, claim_token = ?, lease_expires_at = NULL WHERE delivery_id = ?",
                state, state.equals("LEASED") ? null : "private-token", fixture.record().id().value());
        assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                failure -> assertThat(failure.reason()).isEqualTo(AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID));
        var controller = new io.geordi.alerts.adapter.in.web.AlertHistoryController(
                new io.geordi.alerts.application.AlertHistoryQueryService(fixture.repository(), fixture.repository(),
                        new AlertNotificationProjectionService(fixture.repository())),
                (episodeId, actor, reason) -> { throw new AssertionError("read-only test"); });
        org.springframework.test.web.servlet.setup.MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new io.geordi.alerts.adapter.in.web.AlertHistoryExceptionHandler()).build()
                .perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(
                        "/api/alert-episodes/{id}", fixture.record().episodeId().value()))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isServiceUnavailable())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.detail")
                        .value("Alert history could not be read"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.episode").doesNotExist());
    }

    @ParameterizedTest
    @EnumSource(value = NotificationDeliveryState.class, names = {"LEASED", "DELIVERED", "FAILED"})
    void rejectsOtherwiseValidDurableClaimedOrTerminalRowsWithZeroAttempts(NotificationDeliveryState state) throws Exception {
        Fixture fixture = matched(Instant.parse("2026-08-28T18:00:00Z"));
        if (state == NotificationDeliveryState.LEASED) {
            jdbc.update("""
                    UPDATE alert_notification_outbox
                    SET state = 'LEASED', attempts = 0, claim_token = 'valid-claim',
                        lease_expires_at = ?, completed_at = NULL
                    WHERE delivery_id = ?
                    """, java.sql.Timestamp.from(Instant.parse("2026-08-28T18:01:00Z")),
                    fixture.record().id().value());
        } else {
            jdbc.update("""
                    UPDATE alert_notification_outbox
                    SET state = ?, attempts = 0, claim_token = NULL, lease_expires_at = NULL,
                        completed_at = ?
                    WHERE delivery_id = ?
                    """, state.name(), java.sql.Timestamp.from(Instant.parse("2026-08-28T18:01:00Z")),
                    fixture.record().id().value());
        }

        assertThatThrownBy(fixture::project).isInstanceOfSatisfying(AlertNotificationIntegrityException.class,
                failure -> assertThat(failure.reason())
                        .isEqualTo(AlertNotificationIntegrityException.Reason.STORED_VALUE_INVALID));
        var controller = new io.geordi.alerts.adapter.in.web.AlertHistoryController(
                new io.geordi.alerts.application.AlertHistoryQueryService(fixture.repository(), fixture.repository(),
                        new AlertNotificationProjectionService(fixture.repository())),
                (episodeId, actor, reason) -> { throw new AssertionError("read-only test"); });
        org.springframework.test.web.servlet.setup.MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new io.geordi.alerts.adapter.in.web.AlertHistoryExceptionHandler()).build()
                .perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(
                        "/api/alert-episodes/{id}", fixture.record().episodeId().value()))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isServiceUnavailable())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.detail")
                        .value("Alert history could not be read"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.episode").doesNotExist())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$.transitions").doesNotExist());
    }

    private Fixture matched(Instant time) {
        var repository = new H2AlertLifecycleRepository(jdbc, JsonMapper.builder().findAndAddModules().build(),
                new TransactionTemplate(new JdbcTransactionManager(jdbc.getDataSource())));
        var lifecycle = lifecycle(time);
        var delivery = NotificationDelivery.pending(lifecycle.latestTransition(),
                new NotificationDestination("sensitive-destination", "sensitive-fingerprint"), time);
        var history = AlertHistoryMutation.from(lifecycle.latestTransition());
        assertThat(repository.commit(lifecycle, Optional.empty(), Optional.of(new AlertTransitionCommitIntent(
                history, new NotificationCommitIntent.Matched(delivery))))).isTrue();
        return new Fixture(repository, ((AlertHistoryMutation.Opened) history).record());
    }

    private record Fixture(H2AlertLifecycleRepository repository, AlertTransitionRecord record) {
        AlertNotificationStatus project() {
            return new AlertNotificationProjectionService(repository).project(List.of(record)).getFirst().notification();
        }
    }

    private static AlertLifecycle lifecycle(Instant time) {
        var evaluation = new AlertEvaluation("evidence-burn", "Evidence burn", "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                AlertEvaluationStatus.CONDITION_MET, null,
                new BurnRateEvidence("checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                        EvaluationWindow.PT5M, new TimeRange(time.minusSeconds(300), time), time, new BigDecimal("3"), null));
        return AlertLifecycleTransitions.apply(Optional.empty(), evaluation, null).current();
    }
}
