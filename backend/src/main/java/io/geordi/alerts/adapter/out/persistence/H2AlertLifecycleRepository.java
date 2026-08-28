package io.geordi.alerts.adapter.out.persistence;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycle;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

public final class H2AlertLifecycleRepository implements AlertLifecycleRepository {

    private static final String SELECT_BY_POLICY = """
            SELECT version, aggregate_json
            FROM alert_lifecycle_state
            WHERE policy_id = ?
            """;
    private static final String SELECT_ALL = """
            SELECT version, aggregate_json
            FROM alert_lifecycle_state
            """;
    private static final String INSERT = """
            INSERT INTO alert_lifecycle_state (policy_id, version, aggregate_json)
            VALUES (?, 0, ?)
            """;
    private static final String REPLACE = """
            UPDATE alert_lifecycle_state
            SET version = version + 1, aggregate_json = ?
            WHERE policy_id = ? AND version = ?
            """;

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public H2AlertLifecycleRepository(JdbcTemplate jdbc, ObjectMapper objectMapper) {
        this.jdbc = Objects.requireNonNull(jdbc, "JDBC template must not be null");
        this.objectMapper = Objects.requireNonNull(objectMapper, "object mapper must not be null");
    }

    @Override
    public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
        try {
            List<VersionedAlertLifecycle> matches = jdbc.query(
                    SELECT_BY_POLICY, (result, rowNumber) -> read(result), policyId);
            return matches.stream().findFirst();
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    @Override
    public List<VersionedAlertLifecycle> findAll() {
        try {
            return jdbc.query(SELECT_ALL, (result, rowNumber) -> read(result));
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    @Override
    public boolean insertIfAbsent(AlertLifecycle lifecycle) {
        try {
            return jdbc.update(INSERT, lifecycle.policyId(), write(lifecycle)) == 1;
        } catch (DuplicateKeyException exception) {
            return false;
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    @Override
    public boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion) {
        try {
            return jdbc.update(REPLACE, write(lifecycle), lifecycle.policyId(), expectedVersion) == 1;
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    private VersionedAlertLifecycle read(ResultSet result) throws SQLException {
        try {
            return new VersionedAlertLifecycle(
                    objectMapper.readValue(result.getString("aggregate_json"), AlertLifecycle.class),
                    result.getLong("version"));
        } catch (JsonProcessingException exception) {
            throw new AlertLifecyclePersistenceException("stored alert lifecycle is invalid", exception);
        }
    }

    private String write(AlertLifecycle lifecycle) {
        try {
            return objectMapper.writeValueAsString(lifecycle);
        } catch (JsonProcessingException exception) {
            throw new AlertLifecyclePersistenceException("alert lifecycle could not be serialized", exception);
        }
    }

    private static AlertLifecyclePersistenceException persistenceFailure(DataAccessException exception) {
        return new AlertLifecyclePersistenceException("alert lifecycle persistence operation failed", exception);
    }
}
