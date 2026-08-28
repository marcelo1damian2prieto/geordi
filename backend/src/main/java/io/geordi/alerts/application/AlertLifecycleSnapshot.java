package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.SloLifecycleBindingPort.Binding;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertPolicy;
import java.util.Objects;

public record AlertLifecycleSnapshot(AlertPolicy policy, AlertLifecycle lifecycle) {

    public AlertLifecycleSnapshot {
        Objects.requireNonNull(policy, "snapshot policy must not be null");
        if (lifecycle != null) {
            boolean sameCondition = policy.condition().type() == lifecycle.condition().type()
                    && policy.condition().threshold().compareTo(lifecycle.condition().threshold()) == 0;
            if (!policy.id().equals(lifecycle.policyId())
                    || !policy.sloId().equals(lifecycle.sloId())
                    || !sameCondition) {
                throw new io.geordi.alerts.domain.AlertLifecycleBindingMismatchException();
            }
        }
    }

    public AlertLifecycleSnapshot(AlertPolicy policy, AlertLifecycle lifecycle, Binding currentSloBinding) {
        this(policy, lifecycle);
        validateCurrentSloBinding(policy, lifecycle, currentSloBinding);
    }

    static void validateCurrentSloBinding(
            AlertPolicy policy, AlertLifecycle lifecycle, Binding currentSloBinding) {
        Objects.requireNonNull(currentSloBinding, "current SLO binding must not be null");
        if (!policy.sloId().equals(currentSloBinding.sloId())
                || lifecycle != null && lifecycle.boundService() != null
                        && (!lifecycle.boundService().equals(currentSloBinding.service())
                                || lifecycle.boundWindow() != currentSloBinding.window())) {
            throw new io.geordi.alerts.domain.AlertLifecycleBindingMismatchException();
        }
    }

    public boolean initialized() {
        return lifecycle != null;
    }
}
