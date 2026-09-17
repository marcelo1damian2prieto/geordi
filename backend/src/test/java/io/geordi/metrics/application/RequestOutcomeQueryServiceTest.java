package io.geordi.metrics.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

class RequestOutcomeQueryServiceTest {

    @Test
    void enforcesOneOverallBatchDeadlineCancelsWorkAndReleasesTheNextCall() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        AtomicBoolean interrupted = new AtomicBoolean();
        AtomicBoolean first = new AtomicBoolean(true);
        var batchPort = (io.geordi.metrics.application.port.out.RequestOutcomeBatchQueryPort) query -> {
            if (first.getAndSet(false)) {
                started.countDown();
                try {
                    Thread.sleep(Duration.ofSeconds(10));
                } catch (InterruptedException exception) {
                    interrupted.set(true);
                    Thread.currentThread().interrupt();
                    throw new RequestOutcomeQueryException(
                            RequestOutcomeQueryException.Reason.UNAVAILABLE, "cancelled", exception);
                }
            }
            return new RequestOutcomeBatchMeasurement(Map.of(
                    "PT5M", new RequestOutcomeMeasurement(10d, 1d),
                    "PT1H", new RequestOutcomeMeasurement(100d, 10d)));
        };
        try (var service = new RequestOutcomeQueryService(
                query -> new RequestOutcomeMeasurement(1d, 0d), batchPort, Duration.ofMillis(50))) {
            RequestOutcomeBatchQuery query = query();

            assertThatThrownBy(() -> service.measureBatch(query))
                    .isInstanceOf(RequestOutcomeQueryException.class)
                    .extracting(exception -> ((RequestOutcomeQueryException) exception).reason())
                    .isEqualTo(RequestOutcomeQueryException.Reason.UNAVAILABLE);
            assertThat(started.await(1, TimeUnit.SECONDS)).isTrue();
            for (int attempt = 0; attempt < 20 && !interrupted.get(); attempt++) {
                Thread.sleep(10);
            }
            assertThat(interrupted).isTrue();
            assertThat(service.measureBatch(query).measurements()).containsOnlyKeys("PT5M", "PT1H");
        }
    }

    private static RequestOutcomeBatchQuery query() {
        Instant now = Instant.parse("2026-09-16T12:00:00Z");
        return new RequestOutcomeBatchQuery(
                new ServiceIdentity("checkout", "commerce", "production"),
                List.of(
                        new RequestOutcomeBatchQuery.Window(
                                "PT5M", new TimeRange(now.minus(Duration.ofMinutes(5)), now)),
                        new RequestOutcomeBatchQuery.Window(
                                "PT1H", new TimeRange(now.minus(Duration.ofHours(1)), now))));
    }
}
