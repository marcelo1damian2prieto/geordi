package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.domain.AlertAcknowledgementAttribution;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.alerts.application.AlertHistoryPersistenceException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

class AlertAcknowledgementV8MigrationIntegrationTest {
    @TempDir
    Path directory;

    @ParameterizedTest
    @ValueSource(strings = {"unknown", "partial", "malformed", "actor", "snapshot"})
    void corruptRowsFailBoundedlyRatherThanGuessingIdentity(String corruption) {
        var source = source();
        migrate(source, null);
        loadFrozen(source);
        var jdbc = new JdbcTemplate(source);
        jdbc.execute("ALTER TABLE alert_episode_acknowledgement DROP CONSTRAINT alert_acknowledgement_attribution_check");
        jdbc.update("DELETE FROM alert_episode_acknowledgement");
        insert(jdbc, "AUTHENTICATED_PRINCIPAL", "https://issuer.example", "subject", "Operator");
        String change = switch (corruption) {
            case "unknown" -> "identity_provenance = 'identity-sentinel'";
            case "partial" -> "principal_subject = NULL";
            case "malformed" -> "principal_issuer = 'https://issuer.example/%identity-sentinel'";
            case "actor" -> "actor = 'identity-sentinel'";
            case "snapshot" -> "display_name_snapshot = REPEAT('x', 129)";
            default -> throw new AssertionError();
        };
        jdbc.update("UPDATE alert_episode_acknowledgement SET " + change);
        assertThatThrownBy(() -> repository(source).findByEpisodeId(new AlertEpisodeId("a".repeat(64))))
                .isInstanceOf(AlertHistoryPersistenceException.class)
                .hasMessage("stored acknowledgement attribution is invalid")
                .satisfies(failure -> {
                    for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
                        assertThat(cause.toString()).doesNotContain("identity-sentinel");
                    }
                });
    }

    @Test
    void durableRestartRetainsBothLegacyAndAuthenticatedFacts() {
        String url = "jdbc:h2:file:" + directory.resolve("acknowledgements").toAbsolutePath() + ";DB_CLOSE_ON_EXIT=FALSE";
        var source = new DriverManagerDataSource(url, "sa", "");
        migrate(source, null);
        loadFrozen(source);
        var jdbc = new JdbcTemplate(source);
        jdbc.update("DELETE FROM alert_episode_acknowledgement WHERE episode_id = ?", "a".repeat(64));
        insert(jdbc, "AUTHENTICATED_PRINCIPAL", "https://issuer.example", "subject", " Original 😀 ");
        var authenticated = repository(source).findByEpisodeId(new AlertEpisodeId("a".repeat(64))).orElseThrow();
        var legacy = repository(source).findByEpisodeId(new AlertEpisodeId("b".repeat(64))).orElseThrow();
        jdbc.execute("SHUTDOWN");
        var restarted = new DriverManagerDataSource(url, "sa", "");
        migrate(restarted, null);
        assertThat(repository(restarted).findByEpisodeId(authenticated.episodeId()).orElseThrow()).isEqualTo(authenticated);
        assertThat(repository(restarted).findByEpisodeId(legacy.episodeId()).orElseThrow()).isEqualTo(legacy);
        new JdbcTemplate(restarted).execute("SHUTDOWN");
    }

    @ParameterizedTest
    @ValueSource(strings = {"0", "1", "3", "5", "7"})
    void installsV8FromEmptyAndEveryEarlierBoundary(String target) {
        var source = source();
        if (!"0".equals(target)) migrate(source, target);
        migrate(source, null);
        assertThat(new JdbcTemplate(source).queryForObject(
                "SELECT MAX(CAST(\"version\" AS INT)) FROM \"flyway_schema_history\" WHERE \"success\" = TRUE",
                Integer.class)).isEqualTo(8);
    }

    @Test
    void preservesFrozenRowsAndOldInsertDefaultsWithoutInventingIdentity() {
        var source = source();
        migrate(source, "7");
        loadFrozen(source);
        var jdbc = new JdbcTemplate(source);
        var before = jdbc.queryForList("SELECT episode_id, actor, reason, acknowledged_at FROM alert_episode_acknowledgement ORDER BY episode_id");
        migrate(source, null);
        assertThat(jdbc.queryForList("SELECT episode_id, actor, reason, acknowledged_at FROM alert_episode_acknowledgement ORDER BY episode_id"))
                .isEqualTo(before);
        assertLegacyRows(source);
        jdbc.update("DELETE FROM alert_episode_acknowledgement");
        jdbc.update("DELETE FROM alert_episode");
        loadFrozen(source);
        assertLegacyRows(source);
    }

    @Test
    void checkConstraintRejectsUnknownAndPartialCombinationsIncludingSqlUnknown() {
        var source = source();
        migrate(source, null);
        loadFrozen(source);
        var jdbc = new JdbcTemplate(source);
        jdbc.update("DELETE FROM alert_episode_acknowledgement");
        for (String provenance : new String[] {null, "UNKNOWN", "LEGACY_CALLER_ASSERTED", "AUTHENTICATED_PRINCIPAL"}) {
            for (String issuer : new String[] {null, "", "https://issuer.example"}) {
                for (String subject : new String[] {null, "", "subject"}) {
                    for (String name : new String[] {null, "Operator"}) {
                        boolean legacy = "LEGACY_CALLER_ASSERTED".equals(provenance)
                                && issuer == null && subject == null && name == null;
                        boolean authenticated = "AUTHENTICATED_PRINCIPAL".equals(provenance)
                                && issuer != null && !issuer.isEmpty() && subject != null && !subject.isEmpty();
                        if (legacy || authenticated) {
                            insert(jdbc, provenance, issuer, subject, name);
                            jdbc.update("DELETE FROM alert_episode_acknowledgement");
                        } else {
                            assertThatThrownBy(() -> insert(jdbc, provenance, issuer, subject, name))
                                    .isInstanceOf(DataIntegrityViolationException.class);
                        }
                    }
                }
            }
        }
    }

    @Test
    void dualReaderPreservesMaximumSupplementaryNameSnapshot() {
        var source = source();
        migrate(source, null);
        loadFrozen(source);
        var jdbc = new JdbcTemplate(source);
        jdbc.update("DELETE FROM alert_episode_acknowledgement");
        String name = "😀".repeat(128);
        insert(jdbc, "AUTHENTICATED_PRINCIPAL", "https://issuer.example", "subject", name);
        var actual = repository(source).findByEpisodeId(new AlertEpisodeId("a".repeat(64))).orElseThrow();
        assertThat(actual.attribution()).isEqualTo(
                AlertAcknowledgementAttribution.authenticated("https://issuer.example", "subject", name));
        assertThat(actual.actor()).isEqualTo(name);
    }

    private static void insert(JdbcTemplate jdbc, String provenance, String issuer, String subject, String name) {
        jdbc.update("""
                INSERT INTO alert_episode_acknowledgement
                  (episode_id, actor, reason, acknowledged_at, identity_provenance,
                   principal_issuer, principal_subject, display_name_snapshot)
                VALUES (?, ?, NULL, TIMESTAMP WITH TIME ZONE '2026-08-27 16:00:00.123456789+00', ?, ?, ?, ?)
                """, "a".repeat(64), name == null ? "Authenticated principal" : name, provenance, issuer, subject, name);
    }

    private static void assertLegacyRows(DriverManagerDataSource source) {
        var jdbc = new JdbcTemplate(source);
        assertThat(jdbc.queryForList("SELECT identity_provenance FROM alert_episode_acknowledgement", String.class))
                .containsOnly("LEGACY_CALLER_ASSERTED");
        for (String id : new String[] {"a", "b"}) {
            assertThat(repository(source).findByEpisodeId(new AlertEpisodeId(id.repeat(64))).orElseThrow().attribution())
                    .isEqualTo(AlertAcknowledgementAttribution.legacy());
        }
    }

    private static H2AlertLifecycleRepository repository(DriverManagerDataSource source) {
        return new H2AlertLifecycleRepository(new JdbcTemplate(source), JsonMapper.builder().findAndAddModules().build(),
                new TransactionTemplate(new JdbcTransactionManager(source)));
    }

    private static DriverManagerDataSource source() {
        return new DriverManagerDataSource("jdbc:h2:mem:ack_v8_" + UUID.randomUUID() + ";DB_CLOSE_DELAY=-1", "sa", "");
    }

    private static void migrate(DriverManagerDataSource source, String target) {
        var configuration = Flyway.configure().dataSource(source).locations("classpath:db/migration");
        if (target != null) configuration.target(target);
        configuration.load().migrate();
    }

    private static void loadFrozen(DriverManagerDataSource source) {
        var populator = new ResourceDatabasePopulator(new ClassPathResource(
                "io/geordi/alerts/adapter/out/persistence/compatibility/ack-v7.sql"));
        populator.setSqlScriptEncoding(StandardCharsets.UTF_8.name());
        populator.execute(source);
    }
}
