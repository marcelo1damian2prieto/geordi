package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import java.util.Set;

@FunctionalInterface
public interface BurnRateEvidencePort {

    BurnRateEvidence evaluate(String sloId);

    default MultiwindowBurnRateEvidence evaluate(
            String sloId, Set<AlertObservationWindow> observationWindows) {
        throw new UnsupportedOperationException("multiwindow burn-rate evaluation is not supported");
    }
}
