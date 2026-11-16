package io.geordi.alerts.application;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import org.junit.jupiter.api.Test;

class TrustedScheduledLifecycleEvaluationUseCaseTest {
    @Test
    void invokesSharedCoordinatorWithoutFabricatingAnIdentity() {
        AlertLifecycleEvaluationUseCase coordinator = mock(AlertLifecycleEvaluationUseCase.class);
        new TrustedScheduledLifecycleEvaluationUseCase(coordinator).evaluate("scheduled-policy");
        verify(coordinator).evaluate("scheduled-policy");
    }
}
