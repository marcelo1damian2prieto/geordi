package io.geordi.alerts.domain;

import java.time.Instant;

public sealed interface AlertEvidence permits BurnRateEvidence, MultiwindowBurnRateEvidence {

    String sloId();

    ServiceIdentity service();

    EvaluationWindow configuredSloWindow();

    Instant evaluatedAt();
}
