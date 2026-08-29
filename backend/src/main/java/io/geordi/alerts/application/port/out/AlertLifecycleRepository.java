package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.NotificationDelivery;
import java.util.List;
import java.util.Optional;

public interface AlertLifecycleRepository {

    Optional<VersionedAlertLifecycle> findByPolicyId(String policyId);

    List<VersionedAlertLifecycle> findAll();

    boolean insertIfAbsent(AlertLifecycle lifecycle);

    boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion);

    default boolean commit(
            AlertLifecycle lifecycle, Optional<Long> expectedVersion, Optional<NotificationDelivery> delivery) {
        if (delivery.isPresent()) {
            throw new UnsupportedOperationException("notification delivery commit is not supported");
        }
        return expectedVersion.map(version -> replaceIfVersionMatches(lifecycle, version))
                .orElseGet(() -> insertIfAbsent(lifecycle));
    }
}
