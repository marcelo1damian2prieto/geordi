package io.geordi.slos.application;

public interface BoundedWindowedBurnRateUseCase {

    BoundedWindowedBurnRateResult evaluate(String sloId, BoundedObservationWindowRequest request);
}
