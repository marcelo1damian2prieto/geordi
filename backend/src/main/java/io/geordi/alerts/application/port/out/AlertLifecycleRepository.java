package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertTransitionCommitIntent;
import java.util.List;
import java.util.Optional;

public interface AlertLifecycleRepository {

    Optional<VersionedAlertLifecycle> findByPolicyId(String policyId);

    List<VersionedAlertLifecycle> findAll();

    boolean insertIfAbsent(AlertLifecycle lifecycle);

    boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion);

    default boolean commit(
            AlertLifecycle lifecycle, Optional<Long> expectedVersion, Optional<AlertTransitionCommitIntent> transition) {
        if (transition.isPresent()) {
            throw new UnsupportedOperationException("alert transition commit is not supported");
        }
        return expectedVersion.map(version -> replaceIfVersionMatches(lifecycle, version))
                .orElseGet(() -> insertIfAbsent(lifecycle));
    }

}
