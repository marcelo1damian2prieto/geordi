package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertLifecycle;
import java.util.List;
import java.util.Optional;

public interface AlertLifecycleRepository {

    Optional<VersionedAlertLifecycle> findByPolicyId(String policyId);

    List<VersionedAlertLifecycle> findAll();

    boolean insertIfAbsent(AlertLifecycle lifecycle);

    boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion);
}
