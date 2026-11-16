package io.geordi.alerts.application;

import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PermissionCheck;
import java.util.Objects;

/** Application mutation boundary for operator-triggered lifecycle evaluation. */
public final class AuthorizedManualLifecycleEvaluationUseCase {
    private final AlertLifecycleEvaluationUseCase coordinator;

    public AuthorizedManualLifecycleEvaluationUseCase(AlertLifecycleEvaluationUseCase coordinator) {
        this.coordinator = Objects.requireNonNull(coordinator);
    }

    public AlertLifecycleEvaluationResult evaluate(AuthenticatedPrincipal principal, String policyId) {
        PermissionCheck.require(principal, GeordiPermission.ALERT_EVALUATE);
        return coordinator.evaluate(policyId);
    }
}
