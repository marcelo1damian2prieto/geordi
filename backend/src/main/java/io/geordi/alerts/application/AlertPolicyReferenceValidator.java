package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.SloReferencePort;
import io.geordi.alerts.domain.AlertPolicy;
import java.util.List;
import java.util.Objects;

public final class AlertPolicyReferenceValidator {

    private final SloReferencePort sloReferences;

    public AlertPolicyReferenceValidator(SloReferencePort sloReferences) {
        this.sloReferences = Objects.requireNonNull(sloReferences, "SLO reference port must not be null");
    }

    public void validate(List<AlertPolicy> policies) {
        Objects.requireNonNull(policies, "alert policies must not be null");
        for (AlertPolicy policy : policies) {
            if (!sloReferences.exists(policy.sloId())) {
                throw new IllegalArgumentException("alert policy references an unknown SLO: " + policy.id());
            }
        }
    }
}
