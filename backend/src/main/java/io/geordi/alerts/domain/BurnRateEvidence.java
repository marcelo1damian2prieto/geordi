package io.geordi.alerts.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Objects;

public record BurnRateEvidence(
        String sloId,
        ServiceIdentity service,
        EvaluationWindow window,
        TimeRange range,
        Instant evaluatedAt,
        BigDecimal observedBurnRate,
        AlertUnavailableReason reason) {

    public BurnRateEvidence {
        if (sloId == null || sloId.isBlank()) {
            throw new IllegalArgumentException("evidence SLO id must not be blank");
        }
        Objects.requireNonNull(service, "evidence service must not be null");
        Objects.requireNonNull(window, "evidence window must not be null");
        Objects.requireNonNull(range, "evidence range must not be null");
        Objects.requireNonNull(evaluatedAt, "evidence evaluation time must not be null");
        if (!evaluatedAt.equals(range.to())) {
            throw new IllegalArgumentException("evidence evaluation time must equal range end");
        }
        if (!range.from().plus(window.duration()).equals(range.to())) {
            throw new IllegalArgumentException("evidence range must match its canonical window");
        }
        if (observedBurnRate != null) {
            if (observedBurnRate.signum() < 0 || !Double.isFinite(observedBurnRate.doubleValue())) {
                throw new IllegalArgumentException("observed burn rate must be a finite non-negative number");
            }
            observedBurnRate = observedBurnRate.stripTrailingZeros();
            if (observedBurnRate.signum() > 0 && observedBurnRate.doubleValue() == 0) {
                throw new IllegalArgumentException("positive observed burn rate must remain nonzero publicly");
            }
        }
        if ((observedBurnRate == null) == (reason == null)) {
            throw new IllegalArgumentException("burn evidence requires exactly one of value or unavailable reason");
        }
    }

    public boolean available() {
        return observedBurnRate != null;
    }
}
