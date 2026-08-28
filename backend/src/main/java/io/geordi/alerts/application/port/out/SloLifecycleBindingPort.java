package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import java.util.Objects;
import java.util.Optional;

public interface SloLifecycleBindingPort {

    Optional<Binding> findById(String sloId);

    record Binding(String sloId, ServiceIdentity service, EvaluationWindow window) {

        public Binding {
            Objects.requireNonNull(sloId, "SLO binding id must not be null");
            Objects.requireNonNull(service, "SLO binding service must not be null");
            Objects.requireNonNull(window, "SLO binding window must not be null");
        }
    }
}
