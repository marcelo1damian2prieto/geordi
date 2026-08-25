package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.BurnRateEvidence;

@FunctionalInterface
public interface BurnRateEvidencePort {

    BurnRateEvidence evaluate(String sloId);
}
