package io.geordi.alerts.adapter.out.persistence;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.application.port.out.AlertLifecyclePersistenceHealthProbe;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.NotificationDeliveryWorkRepository;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDeliveryState;
import io.geordi.alerts.domain.NotificationDestination;
import java.sql.Timestamp;
import java.time.Instant;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionTemplate;

public final class H2AlertLifecycleRepository
        implements AlertLifecycleRepository, AlertLifecyclePersistenceHealthProbe, NotificationDeliveryWorkRepository {

    private static final String AVAILABILITY_CHECK = """
            SELECT
                (SELECT COUNT(*) FROM alert_lifecycle_state WHERE 1 = 0)
              + (SELECT COUNT(*) FROM alert_notification_outbox WHERE 1 = 0)
            """;

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
    private static final String INSERT_NOTIFICATION = """
            INSERT INTO alert_notification_outbox (
                delivery_id, policy_id, transition_type, occurred_at, destination_id,
                destination_fingerprint, payload_json, state, attempts, created_at, next_attempt_at,
                claim_token, lease_expires_at, completed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """;
    private static final String SELECT_DUE_NOTIFICATIONS = """
            SELECT delivery_id, destination_id, destination_fingerprint, payload_json, state, attempts,
                   created_at, next_attempt_at, claim_token, lease_expires_at, completed_at
            FROM alert_notification_outbox
            WHERE ((state = 'PENDING' AND next_attempt_at <= ?)
               OR (state = 'LEASED' AND lease_expires_at <= ?))
              AND attempts < ?
            ORDER BY next_attempt_at, delivery_id
            LIMIT ?
            """;
    private static final String CLAIM_NOTIFICATION = """
            UPDATE alert_notification_outbox
            SET state = 'LEASED', attempts = attempts + 1, claim_token = ?, lease_expires_at = ?, completed_at = NULL
            WHERE delivery_id = ?
              AND attempts < ?
              AND ((state = 'PENDING' AND next_attempt_at <= ?)
                   OR (state = 'LEASED' AND lease_expires_at <= ?))
            """;
    private static final String EXPIRE_EXHAUSTED_NOTIFICATIONS = """
            UPDATE alert_notification_outbox
            SET state = 'FAILED', claim_token = NULL, lease_expires_at = NULL, completed_at = ?
            WHERE state = 'LEASED' AND lease_expires_at <= ? AND attempts >= ?
            """;
    private static final String MARK_DELIVERED = """
            UPDATE alert_notification_outbox
            SET state = 'DELIVERED', claim_token = NULL,
                lease_expires_at = NULL, completed_at = ?
            WHERE delivery_id = ? AND state = 'LEASED' AND claim_token = ?
            """;
    private static final String RESCHEDULE_NOTIFICATION = """
            UPDATE alert_notification_outbox
            SET state = 'PENDING', next_attempt_at = ?, claim_token = NULL,
                lease_expires_at = NULL, completed_at = NULL
            WHERE delivery_id = ? AND state = 'LEASED' AND claim_token = ?
            """;
    private static final String MARK_NOTIFICATION_FAILED = """
            UPDATE alert_notification_outbox
            SET state = 'FAILED', claim_token = NULL,
                lease_expires_at = NULL, completed_at = ?
            WHERE delivery_id = ? AND state = 'LEASED' AND claim_token = ?
            """;

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate transactions;

    public H2AlertLifecycleRepository(JdbcTemplate jdbc, ObjectMapper objectMapper) {
        this(jdbc, objectMapper, null);
    }

    public H2AlertLifecycleRepository(
            JdbcTemplate jdbc, ObjectMapper objectMapper, TransactionTemplate transactions) {
        this.jdbc = Objects.requireNonNull(jdbc, "JDBC template must not be null");
        this.objectMapper = Objects.requireNonNull(objectMapper, "object mapper must not be null");
        this.transactions = transactions;
    }

    @Override
    public boolean isAvailable() {
        try {
            return jdbc.queryForObject(AVAILABILITY_CHECK, Integer.class) != null;
        } catch (DataAccessException exception) {
            return false;
        }
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

    @Override
    public boolean commit(
            AlertLifecycle lifecycle, Optional<Long> expectedVersion, Optional<NotificationDelivery> delivery) {
        Objects.requireNonNull(lifecycle, "alert lifecycle must not be null");
        Objects.requireNonNull(expectedVersion, "expected lifecycle version must not be null");
        Objects.requireNonNull(delivery, "notification delivery must not be null");
        if (delivery.isEmpty()) {
            return expectedVersion.map(version -> replaceIfVersionMatches(lifecycle, version))
                    .orElseGet(() -> insertIfAbsent(lifecycle));
        }
        if (transactions == null) {
            throw new AlertLifecyclePersistenceException(
                    "transactional notification persistence is not configured", new IllegalStateException());
        }
        Boolean committed = transactions.execute(status -> {
            boolean stateSaved = expectedVersion.map(version -> replaceIfVersionMatches(lifecycle, version))
                    .orElseGet(() -> insertIfAbsent(lifecycle));
            if (!stateSaved) {
                status.setRollbackOnly();
                return false;
            }
            insertNotification(delivery.orElseThrow());
            return true;
        });
        return Boolean.TRUE.equals(committed);
    }

    @Override
    public List<NotificationDelivery> claimDue(
            Instant now, Instant leaseExpiresAt, int limit, int maximumAttempts) {
        Objects.requireNonNull(now, "notification claim time must not be null");
        Objects.requireNonNull(leaseExpiresAt, "notification lease expiry must not be null");
        if (!leaseExpiresAt.isAfter(now)) {
            throw new IllegalArgumentException("notification lease expiry must be after claim time");
        }
        if (limit <= 0) {
            throw new IllegalArgumentException("notification claim limit must be positive");
        }
        if (maximumAttempts <= 0) {
            throw new IllegalArgumentException("notification maximum attempts must be positive");
        }
        if (transactions == null) {
            throw new AlertLifecyclePersistenceException(
                    "transactional notification persistence is not configured", new IllegalStateException());
        }
        List<NotificationDelivery> claimed = transactions.execute(status -> {
            jdbc.update(EXPIRE_EXHAUSTED_NOTIFICATIONS, Timestamp.from(now), Timestamp.from(now), maximumAttempts);
            List<NotificationDelivery> due = findDue(now, limit, maximumAttempts);
            List<NotificationDelivery> accepted = new ArrayList<>();
            for (NotificationDelivery delivery : due) {
                String token = UUID.randomUUID().toString();
                if (jdbc.update(
                                CLAIM_NOTIFICATION,
                                token,
                                Timestamp.from(leaseExpiresAt),
                                delivery.id(),
                                maximumAttempts,
                                Timestamp.from(now),
                                Timestamp.from(now))
                        == 1) {
                    accepted.add(delivery.leased(token, leaseExpiresAt));
                }
            }
            return List.copyOf(accepted);
        });
        return claimed == null ? List.of() : claimed;
    }

    @Override
    public boolean markDelivered(String deliveryId, String claimToken, Instant completedAt) {
        return updateClaimed(MARK_DELIVERED, completedAt, deliveryId, claimToken);
    }

    @Override
    public boolean reschedule(String deliveryId, String claimToken, Instant nextAttemptAt) {
        return updateClaimed(RESCHEDULE_NOTIFICATION, nextAttemptAt, deliveryId, claimToken);
    }

    @Override
    public boolean markFailed(String deliveryId, String claimToken, Instant completedAt) {
        return updateClaimed(MARK_NOTIFICATION_FAILED, completedAt, deliveryId, claimToken);
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

    private void insertNotification(NotificationDelivery delivery) {
        try {
            jdbc.update(
                    INSERT_NOTIFICATION,
                    delivery.id(),
                    delivery.transition().policyId(),
                    delivery.transition().type().name(),
                    Timestamp.from(delivery.transition().occurredAt()),
                    delivery.destination().id(),
                    delivery.destination().configurationFingerprint(),
                    objectMapper.writeValueAsString(delivery.transition()),
                    delivery.state().name(),
                    delivery.attempts(),
                    Timestamp.from(delivery.createdAt()),
                    Timestamp.from(delivery.nextAttemptAt()),
                    delivery.claimToken(),
                    timestamp(delivery.leaseExpiresAt()),
                    timestamp(delivery.completedAt()));
        } catch (JsonProcessingException exception) {
            throw new AlertLifecyclePersistenceException("notification delivery could not be serialized", exception);
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    private List<NotificationDelivery> findDue(Instant now, int limit, int maximumAttempts) {
        try {
            return jdbc.query(
                    SELECT_DUE_NOTIFICATIONS,
                    (result, rowNumber) -> readNotification(result),
                    Timestamp.from(now), Timestamp.from(now), maximumAttempts, limit);
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    private NotificationDelivery readNotification(ResultSet result) throws SQLException {
        try {
            return new NotificationDelivery(
                    result.getString("delivery_id"),
                    objectMapper.readValue(result.getString("payload_json"), io.geordi.alerts.domain.AlertTransition.class),
                    new NotificationDestination(
                            result.getString("destination_id"), result.getString("destination_fingerprint")),
                    NotificationDeliveryState.valueOf(result.getString("state")),
                    result.getInt("attempts"),
                    instant(result, "created_at"),
                    instant(result, "next_attempt_at"),
                    result.getString("claim_token"),
                    instant(result, "lease_expires_at"),
                    instant(result, "completed_at"));
        } catch (JsonProcessingException | IllegalArgumentException exception) {
            throw new AlertLifecyclePersistenceException("stored notification delivery is invalid", exception);
        }
    }

    private boolean updateClaimed(String statement, Instant time, String deliveryId, String claimToken) {
        Objects.requireNonNull(time, "notification delivery update time must not be null");
        requireText(deliveryId, "notification delivery id must not be blank");
        requireText(claimToken, "notification delivery claim token must not be blank");
        try {
            return jdbc.update(statement, Timestamp.from(time), deliveryId, claimToken) == 1;
        } catch (DataAccessException exception) {
            throw persistenceFailure(exception);
        }
    }

    private static Instant instant(ResultSet result, String column) throws SQLException {
        Timestamp timestamp = result.getTimestamp(column);
        return timestamp == null ? null : timestamp.toInstant();
    }

    private static Timestamp timestamp(Instant value) {
        return value == null ? null : Timestamp.from(value);
    }

    private static void requireText(String value, String message) {
        if (Objects.requireNonNull(value, message).isBlank()) {
            throw new IllegalArgumentException(message);
        }
    }

    private static AlertLifecyclePersistenceException persistenceFailure(DataAccessException exception) {
        return new AlertLifecyclePersistenceException("alert lifecycle persistence operation failed", exception);
    }
}
