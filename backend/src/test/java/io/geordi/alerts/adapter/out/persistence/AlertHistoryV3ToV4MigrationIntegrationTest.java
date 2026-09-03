package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.geordi.alerts.application.port.out.AlertTransitionHistoryQuery;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionId;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class AlertHistoryV3ToV4MigrationIntegrationTest {

    private static final String EPISODE_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static final String POLICY_ID = "migration-policy-a";
    private static final Instant NANOSECONDS = Instant.parse("2026-09-02T12:34:56.123456789Z");
    private static final Instant MICROSECONDS = Instant.parse("2026-09-02T12:35:56.123456Z");

    @Test
    void h2ReconstructsProductionNumericEpochSecondsAtNanosecondPrecision() throws JsonProcessingException {
        JdbcTemplate jdbc = new JdbcTemplate(isolatedDataSource("m14_numeric_epoch_proof"));
        ObjectMapper jsonMapper = JsonMapper.builder()
                .findAndAddModules()
                .build();

        assertThat(jsonMapper.writeValueAsString(NANOSECONDS)).isEqualTo("1788352496.123456789");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(42))).isEqualTo("42.000000000");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(42, 120_000_000)))
                .isEqualTo("42.120000000");
        assertThat(jsonMapper.writeValueAsString(Instant.EPOCH)).isEqualTo("0.0");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(0, 1))).isEqualTo("1E-9");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(0, 10))).isEqualTo("1.0E-8");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(0, 1_000))).isEqualTo("0.000001000");
        assertThat(jsonMapper.writeValueAsString(Instant.ofEpochSecond(-1, 500_000_000)))
                .isEqualTo("-1.500000000");
        assertThat(jsonMapper.readValue("-1.500000000", Instant.class))
                .isEqualTo(Instant.ofEpochSecond(-1, 500_000_000));
        assertThat(jdbc.queryForObject("SELECT CAST(? AS VARCHAR) IS JSON OBJECT", Boolean.class,
                        "{\"occurredAt\":1788352496.123456789}"))
                .isTrue();
        assertThat(jdbc.queryForObject("SELECT CAST(? AS VARCHAR) IS JSON OBJECT", Boolean.class, "{not-json"))
                .isFalse();

        String decimal = "CAST(? AS DECIMAL(29, 9))";
        String expression = "DATEADD(NANOSECOND, CAST(ABS(" + decimal + " - TRUNC(" + decimal
                + ")) * 1000000000 AS BIGINT), DATEADD(SECOND, CAST(TRUNC(" + decimal
                + ") AS BIGINT), TIMESTAMP WITH TIME ZONE '1970-01-01 00:00:00+00'))";
        assertThat(reconstruct(jdbc, expression, "1788352496.123456789", "1788352496.123456789",
                        "1788352496.123456789"))
                .isEqualTo(NANOSECONDS);
        assertThat(reconstruct(jdbc, expression, "42.000000000", "42.000000000", "42.000000000"))
                .isEqualTo(Instant.ofEpochSecond(42));
        assertThat(reconstruct(jdbc, expression, "42.120000000", "42.120000000", "42.120000000"))
                .isEqualTo(Instant.ofEpochSecond(42, 120_000_000));
        assertThat(reconstruct(jdbc, expression, "-1.500000000", "-1.500000000", "-1.500000000"))
                .isEqualTo(Instant.ofEpochSecond(-1, 500_000_000));
        assertThat(reconstruct(jdbc, expression, "0.0", "0.0", "0.0")).isEqualTo(Instant.EPOCH);
        assertThat(reconstruct(jdbc, expression, "1E-9", "1E-9", "1E-9"))
                .isEqualTo(Instant.ofEpochSecond(0, 1));
    }

    @Test
    void upgradesPopulatedV3HistoryAndReadsReconciledTransitionsThroughTheProductionAdapter()
            throws JsonProcessingException {
        DriverManagerDataSource dataSource = isolatedDataSource("m14_v3_upgrade");
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        migrate(dataSource, "3");
        assertThat(version(jdbc)).isEqualTo("3");

        ObjectMapper jsonMapper = JsonMapper.builder()
                .findAndAddModules()
                .build();
        AlertTransition started = transition(AlertTransitionType.ALERT_STARTED, NANOSECONDS);
        AlertTransition resolved = transition(AlertTransitionType.ALERT_RESOLVED, MICROSECONDS);
        String startJson = jsonMapper.writeValueAsString(started);
        String resolveJson = jsonMapper.writeValueAsString(resolved);
        String startId = AlertTransitionId.from(started).value();
        String resolveId = AlertTransitionId.from(resolved).value();

        assertThat(startJson).contains("\"occurredAt\":1788352496.123456789");
        jdbc.update(
                "INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin) VALUES (?, ?, ?, ?, ?)",
                EPISODE_ID, POLICY_ID, Timestamp.from(NANOSECONDS), Timestamp.from(MICROSECONDS), "M14");
        insert(jdbc, startId, startJson, started);
        insert(jdbc, resolveId, resolveJson, resolved);

        Instant before = occurredAt(jdbc, startId);
        assertThat(before).isEqualTo(Instant.parse("2026-09-02T12:34:56.123457Z"));
        List<TransitionColumns> beforeColumns = transitionColumns(jdbc);

        migrate(dataSource, null);

        assertThat(version(jdbc)).isEqualTo("4");
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM \"flyway_schema_history\" WHERE \"version\" = '4' AND \"success\" = TRUE",
                        Integer.class))
                .isEqualTo(1);
        assertThat(occurredAt(jdbc, startId)).isEqualTo(NANOSECONDS);
        assertThat(episodeTime(jdbc, "opened_at")).isEqualTo(NANOSECONDS);
        assertThat(episodeTime(jdbc, "closed_at")).isEqualTo(MICROSECONDS);
        assertThat(jdbc.queryForObject(
                        "SELECT transition_json FROM alert_transition_history WHERE transition_id = ?",
                        String.class, startId))
                .isEqualTo(startJson);
        assertThat(jdbc.queryForObject(
                        "SELECT transition_json FROM alert_transition_history WHERE transition_id = ?",
                        String.class, resolveId))
                .isEqualTo(resolveJson);
        assertThat(transitionColumns(jdbc))
                .usingRecursiveComparison()
                .ignoringFields("occurredAt")
                .isEqualTo(beforeColumns);
        assertThat(transitionColumns(jdbc)).extracting(TransitionColumns::occurredAt)
                .containsExactly(MICROSECONDS, NANOSECONDS);
        assertThat(jdbc.queryForObject(
                        "SELECT episode_id || ':' || policy_id FROM alert_episode", String.class))
                .isEqualTo(EPISODE_ID + ":" + POLICY_ID);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM alert_transition_history", Integer.class)).isEqualTo(2);

        H2AlertLifecycleRepository repository = new H2AlertLifecycleRepository(jdbc, jsonMapper);
        List<AlertTransitionRecord> transitions = repository.findTransitions(
                new AlertTransitionHistoryQuery(POLICY_ID, null, null, null, 100));

        assertThat(transitions).hasSize(2);
        assertThat(transitions).extracting(AlertTransitionRecord::id)
                .containsExactly(AlertTransitionId.from(resolved), AlertTransitionId.from(started));
        assertThat(transitions).extracting(record -> record.episodeId().value())
                .containsExactly(EPISODE_ID, EPISODE_ID);
        assertThat(transitions).extracting(record -> record.transition().policyId())
                .containsExactly(POLICY_ID, POLICY_ID);
        assertThat(transitions).extracting(record -> record.transition().type())
                .containsExactly(AlertTransitionType.ALERT_RESOLVED, AlertTransitionType.ALERT_STARTED);
        assertThat(transitions).extracting(record -> record.transition().previousState())
                .containsExactly(AlertLifecycleState.FIRING, AlertLifecycleState.INACTIVE);
        assertThat(transitions).extracting(record -> record.transition().currentState())
                .containsExactly(AlertLifecycleState.INACTIVE, AlertLifecycleState.FIRING);
        assertThat(transitions).extracting(record -> record.transition().occurredAt())
                .containsExactly(MICROSECONDS, NANOSECONDS);
        assertThat(transitions).extracting(AlertTransitionRecord::transition)
                .containsExactly(resolved, started);
    }

    @Test
    void rejectsV3CanonicalHistoryWithoutOccurredAt() throws JsonProcessingException {
        CorruptFixture fixture = corruptFixture("m14_missing_occurred_at");
        ObjectNode canonical = (ObjectNode) fixture.jsonMapper().readTree(fixture.canonicalJson());
        canonical.remove("occurredAt");
        fixture.insert(canonical.toString());
        assertV4MigrationFails(fixture);
    }

    @Test
    void rejectsV3CanonicalHistoryWithInvalidOccurredAt() throws JsonProcessingException {
        CorruptFixture fixture = corruptFixture("m14_invalid_occurred_at");
        ObjectNode canonical = (ObjectNode) fixture.jsonMapper().readTree(fixture.canonicalJson());
        canonical.put("occurredAt", "not-a-timestamp");
        fixture.insert(canonical.toString());
        assertV4MigrationFails(fixture);
    }

    @Test
    void v3AcceptsMalformedCanonicalJsonButV4RejectsIt() {
        CorruptFixture fixture = corruptFixture("m14_malformed_json");
        fixture.insert("{not-json");
        assertThat(fixture.jdbc().queryForObject(
                        "SELECT transition_json FROM alert_transition_history", String.class))
                .isEqualTo("{not-json");
        assertV4MigrationFails(fixture);
    }

    private static CorruptFixture corruptFixture(String name) {
        DriverManagerDataSource dataSource = isolatedDataSource(name);
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        migrate(dataSource, "3");
        ObjectMapper jsonMapper = JsonMapper.builder()
                .findAndAddModules()
                .build();
        AlertTransition transition = transition(AlertTransitionType.ALERT_STARTED, NANOSECONDS);
        try {
            return new CorruptFixture(dataSource, jdbc, jsonMapper, transition,
                    jsonMapper.writeValueAsString(transition));
        } catch (JsonProcessingException exception) {
            throw new AssertionError("production transition must serialize", exception);
        }
    }

    private static void assertV4MigrationFails(CorruptFixture fixture) {
        assertThatThrownBy(() -> migrate(fixture.dataSource(), null)).isInstanceOf(FlywayException.class);
        assertThat(fixture.jdbc().queryForObject(
                        "SELECT COUNT(*) FROM \"flyway_schema_history\" WHERE \"version\" = '4' AND \"success\" = TRUE",
                        Integer.class))
                .isZero();
    }

    private static AlertTransition transition(AlertTransitionType type, Instant occurredAt) {
        AlertEvaluationStatus status = type == AlertTransitionType.ALERT_STARTED
                ? AlertEvaluationStatus.CONDITION_MET
                : AlertEvaluationStatus.CONDITION_NOT_MET;
        BigDecimal burnRate = type == AlertTransitionType.ALERT_STARTED
                ? new BigDecimal("3")
                : new BigDecimal("0.5");
        BurnRateEvidence evidence = new BurnRateEvidence(
                "migration-slo-a",
                new ServiceIdentity("migration-service", "migration-namespace", "test"),
                EvaluationWindow.PT5M,
                new TimeRange(occurredAt.minusSeconds(300), occurredAt),
                occurredAt,
                burnRate,
                null);
        AlertEvaluation evaluation = new AlertEvaluation(
                POLICY_ID,
                "Migration policy A",
                "migration-slo-a",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")),
                status,
                null,
                evidence);
        return type == AlertTransitionType.ALERT_STARTED
                ? new AlertTransition(POLICY_ID, type, AlertLifecycleState.INACTIVE,
                        AlertLifecycleState.FIRING, occurredAt, evaluation)
                : new AlertTransition(POLICY_ID, type, AlertLifecycleState.FIRING,
                        AlertLifecycleState.INACTIVE, occurredAt, evaluation);
    }

    private static DriverManagerDataSource isolatedDataSource(String name) {
        return new DriverManagerDataSource(
                "jdbc:h2:mem:" + name + '_' + UUID.randomUUID() + ";DB_CLOSE_DELAY=-1", "sa", "");
    }

    private static void migrate(DataSource dataSource, String target) {
        var configuration = Flyway.configure().dataSource(dataSource).locations("classpath:db/migration");
        if (target != null) {
            configuration.target(MigrationVersion.fromVersion(target));
        }
        configuration.load().migrate();
    }

    private static String version(JdbcTemplate jdbc) {
        return jdbc.queryForObject(
                "SELECT \"version\" FROM \"flyway_schema_history\" WHERE \"success\" = TRUE "
                        + "ORDER BY \"installed_rank\" DESC LIMIT 1",
                String.class);
    }

    private static void insert(JdbcTemplate jdbc, String id, String json, AlertTransition transition) {
        jdbc.update(
                "INSERT INTO alert_transition_history (transition_id, episode_id, policy_id, transition_type, "
                        + "occurred_at, previous_state, current_state, transition_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                id, EPISODE_ID, transition.policyId(), transition.type().name(),
                Timestamp.from(transition.occurredAt()), transition.previousState().name(),
                transition.currentState().name(), json);
    }

    private static Instant occurredAt(JdbcTemplate jdbc, String transitionId) {
        return jdbc.queryForObject(
                "SELECT occurred_at FROM alert_transition_history WHERE transition_id = ?",
                (result, rowNumber) -> result.getTimestamp(1).toInstant(), transitionId);
    }

    private static Instant episodeTime(JdbcTemplate jdbc, String column) {
        return jdbc.queryForObject(
                "SELECT " + column + " FROM alert_episode WHERE episode_id = ?",
                (result, rowNumber) -> result.getTimestamp(1).toInstant(), EPISODE_ID);
    }

    private static Instant reconstruct(JdbcTemplate jdbc, String expression, String... epochSeconds) {
        Object[] arguments = epochSeconds;
        return jdbc.queryForObject(
                "SELECT " + expression,
                (result, rowNumber) -> result.getTimestamp(1).toInstant(),
                arguments);
    }

    private static List<TransitionColumns> transitionColumns(JdbcTemplate jdbc) {
        return jdbc.query(
                "SELECT transition_id, episode_id, policy_id, transition_type, occurred_at, previous_state, "
                        + "current_state FROM alert_transition_history ORDER BY occurred_at DESC, transition_id DESC",
                (result, rowNumber) -> new TransitionColumns(
                        result.getString("transition_id"), result.getString("episode_id"),
                        result.getString("policy_id"), result.getString("transition_type"),
                        result.getTimestamp("occurred_at").toInstant(), result.getString("previous_state"),
                        result.getString("current_state")));
    }

    private record TransitionColumns(
            String transitionId, String episodeId, String policyId, String transitionType,
            Instant occurredAt, String previousState, String currentState) {}

    private record CorruptFixture(
            DriverManagerDataSource dataSource, JdbcTemplate jdbc, ObjectMapper jsonMapper,
            AlertTransition transition, String canonicalJson) {

        private void insert(String json) {
            jdbc.update(
                    "INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin) "
                            + "VALUES (?, ?, ?, ?, ?)",
                    EPISODE_ID, POLICY_ID, Timestamp.from(NANOSECONDS), null, "M14");
            AlertHistoryV3ToV4MigrationIntegrationTest.insert(
                    jdbc, AlertTransitionId.from(transition).value(), json, transition);
        }
    }
}
