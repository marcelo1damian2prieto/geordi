package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class AlertNotificationDispositionV7MigrationIntegrationTest {

    private static final String EPISODE_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static final String TRANSITION_ID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private static final String DELIVERY_ID = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    private static final String POLICY_ID = "migration-policy";
    private static final Instant OCCURRED_AT = Instant.parse("2026-09-10T18:30:00.123456Z");

    @Test
    void installsV1ThroughV7OnACleanDatabase() {
        DriverManagerDataSource dataSource = isolatedDataSource("m17_clean_v7");
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);

        migrate(dataSource, null);

        assertThat(version(jdbc)).isEqualTo("7");
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM information_schema.tables "
                                + "WHERE table_name = 'ALERT_NOTIFICATION_DISPOSITION'",
                        Integer.class))
                .isOne();
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM alert_notification_disposition", Integer.class))
                .isZero();
    }

    @Test
    void upgradesPopulatedV6WithoutChangingRowsOrBackfillingDispositions() {
        DriverManagerDataSource dataSource = isolatedDataSource("m17_populated_v6");
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        migrate(dataSource, "6");
        insertPopulatedV6Fixture(jdbc);
        V6Snapshot before = snapshot(jdbc);

        migrate(dataSource, null);

        assertThat(version(jdbc)).isEqualTo("7");
        assertThat(snapshot(jdbc)).isEqualTo(before);
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM alert_notification_disposition", Integer.class))
                .isZero();
    }

    @Test
    void enforcesTransitionForeignKeyPrimaryKeyNotNullAndClosedDispositionValues() {
        DriverManagerDataSource dataSource = isolatedDataSource("m17_v7_constraints");
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        migrate(dataSource, null);
        insertEpisodeAndTransition(jdbc);

        assertThatThrownBy(() -> jdbc.update(
                        "INSERT INTO alert_notification_disposition (transition_id, disposition) VALUES (?, ?)",
                        "d".repeat(64), "MATCHED"))
                .isInstanceOf(DataIntegrityViolationException.class);

        assertThat(jdbc.update(
                        "INSERT INTO alert_notification_disposition (transition_id, disposition) VALUES (?, ?)",
                        TRANSITION_ID, "MATCHED"))
                .isOne();
        assertThatThrownBy(() -> jdbc.update(
                        "INSERT INTO alert_notification_disposition (transition_id, disposition) VALUES (?, ?)",
                        TRANSITION_ID, "SUPPRESSED"))
                .isInstanceOf(DataIntegrityViolationException.class);

        jdbc.update("DELETE FROM alert_notification_disposition");
        assertThatThrownBy(() -> jdbc.update(
                        "INSERT INTO alert_notification_disposition (transition_id, disposition) VALUES (?, ?)",
                        TRANSITION_ID, null))
                .isInstanceOf(DataIntegrityViolationException.class);

        for (String invalid : new String[] {"NOT_RECORDED", "UNKNOWN", "matched", " MATCHED "}) {
            assertThatThrownBy(() -> jdbc.update(
                            "INSERT INTO alert_notification_disposition (transition_id, disposition) VALUES (?, ?)",
                            TRANSITION_ID, invalid))
                    .as("stored disposition %s must be rejected", invalid)
                    .isInstanceOf(DataIntegrityViolationException.class);
        }
        assertThat(jdbc.queryForObject(
                        "SELECT COUNT(*) FROM alert_notification_disposition", Integer.class))
                .isZero();
    }

    private static void insertPopulatedV6Fixture(JdbcTemplate jdbc) {
        jdbc.update("INSERT INTO alert_lifecycle_state (policy_id, version, aggregate_json) VALUES (?, ?, ?)",
                POLICY_ID, 7L, "{\"preserved\":true}");
        insertEpisodeAndTransition(jdbc);
        jdbc.update(
                "INSERT INTO alert_episode_acknowledgement "
                        + "(episode_id, actor, reason, acknowledged_at) VALUES (?, ?, ?, ?)",
                EPISODE_ID, "migration-operator", "preserve this reason", Timestamp.from(OCCURRED_AT.plusSeconds(1)));
        jdbc.update(
                """
                INSERT INTO alert_notification_outbox (
                    delivery_id, policy_id, transition_type, occurred_at,
                    destination_id, destination_fingerprint, payload_json,
                    state, attempts, created_at, next_attempt_at,
                    claim_token, lease_expires_at, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                DELIVERY_ID, POLICY_ID, "ALERT_STARTED", Timestamp.from(OCCURRED_AT),
                "operations", "configuration-fingerprint", "{\"preserved\":\"payload\"}",
                "LEASED", 2, Timestamp.from(OCCURRED_AT.plusSeconds(2)),
                Timestamp.from(OCCURRED_AT.plusSeconds(3)), "lease-token",
                Timestamp.from(OCCURRED_AT.plusSeconds(4)), null);
    }

    private static void insertEpisodeAndTransition(JdbcTemplate jdbc) {
        jdbc.update(
                "INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin) "
                        + "VALUES (?, ?, ?, ?, ?)",
                EPISODE_ID, POLICY_ID, Timestamp.from(OCCURRED_AT), null, "M14");
        jdbc.update(
                "INSERT INTO alert_transition_history (transition_id, episode_id, policy_id, transition_type, "
                        + "occurred_at, previous_state, current_state, transition_json) "
                        + "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                TRANSITION_ID, EPISODE_ID, POLICY_ID, "ALERT_STARTED", Timestamp.from(OCCURRED_AT),
                "INACTIVE", "FIRING", "{\"preserved\":\"transition\"}");
    }

    private static V6Snapshot snapshot(JdbcTemplate jdbc) {
        return new V6Snapshot(
                jdbc.queryForMap("SELECT policy_id, version, CAST(aggregate_json AS VARCHAR) AS aggregate_json "
                        + "FROM alert_lifecycle_state"),
                jdbc.queryForMap("SELECT episode_id, policy_id, opened_at, closed_at, origin, open_policy_id "
                        + "FROM alert_episode"),
                jdbc.queryForMap("SELECT transition_id, episode_id, policy_id, transition_type, occurred_at, "
                        + "previous_state, current_state, CAST(transition_json AS VARCHAR) AS transition_json "
                        + "FROM alert_transition_history"),
                jdbc.queryForMap("SELECT episode_id, actor, reason, acknowledged_at "
                        + "FROM alert_episode_acknowledgement"),
                jdbc.queryForMap("SELECT delivery_id, policy_id, transition_type, occurred_at, destination_id, "
                        + "destination_fingerprint, CAST(payload_json AS VARCHAR) AS payload_json, state, attempts, "
                        + "created_at, next_attempt_at, claim_token, lease_expires_at, completed_at "
                        + "FROM alert_notification_outbox"));
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

    private record V6Snapshot(
            Map<String, Object> lifecycle,
            Map<String, Object> episode,
            Map<String, Object> transition,
            Map<String, Object> acknowledgement,
            Map<String, Object> outbox) { }
}
