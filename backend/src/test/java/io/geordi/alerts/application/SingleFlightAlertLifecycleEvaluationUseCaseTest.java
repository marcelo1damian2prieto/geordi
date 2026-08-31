package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class SingleFlightAlertLifecycleEvaluationUseCaseTest {
    @Test
    void rejectsAConcurrentEvaluationOfTheSamePolicy() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AlertLifecycleEvaluationUseCase useCase = new SingleFlightAlertLifecycleEvaluationUseCase(policyId -> {
            entered.countDown();
            try { release.await(5, TimeUnit.SECONDS); } catch (InterruptedException exception) { Thread.currentThread().interrupt(); }
            return null;
        });
        Thread first = new Thread(() -> useCase.evaluate("policy"));
        first.start();
        entered.await(5, TimeUnit.SECONDS);
        assertThatThrownBy(() -> useCase.evaluate("policy"))
                .isInstanceOf(AlertLifecycleEvaluationInProgressException.class);
        release.countDown();
        first.join(5000);
    }
}
