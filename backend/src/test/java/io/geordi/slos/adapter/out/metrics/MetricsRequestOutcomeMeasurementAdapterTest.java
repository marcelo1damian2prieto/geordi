package io.geordi.slos.adapter.out.metrics;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.metrics.application.RequestOutcomeBatchMeasurement;
import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.application.RequestOutcomeQueryService;
import io.geordi.slos.application.BoundedRequestOutcomeMeasurementRequest;
import io.geordi.slos.application.MetricsMeasurementUnavailableException;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.TimeRange;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

class MetricsRequestOutcomeMeasurementAdapterTest {

    private static final Instant NOW = Instant.parse("2026-08-20T18:00:00Z");

    @Test
    void translatesAllWindowsInOneCorrelatedMetricsBatchAndKeepsAbsentWindowsMissing() {
        var calls = new java.util.concurrent.atomic.AtomicInteger();
        RequestOutcomeQueryService metrics = new RequestOutcomeQueryService(
                ignored -> {
                    throw new AssertionError("legacy scalar measurement must not be used");
                },
                query -> {
                    calls.incrementAndGet();
                    assertThat(query.windows()).extracting(window -> window.correlationKey())
                            .containsExactly("PT5M", "PT1H");
                    assertThat(query.windows()).allSatisfy(window -> assertThat(window.range().to()).isEqualTo(NOW));
                    return new RequestOutcomeBatchMeasurement(Map.of(
                            "PT5M", new io.geordi.metrics.application.RequestOutcomeMeasurement(20d, 1d)));
                });

        var result = new MetricsRequestOutcomeMeasurementAdapter(metrics).measureBounded(request());

        assertThat(calls).hasValue(1);
        assertThat(result.measurements().get(Duration.ofMinutes(5)).requestCount()).isEqualTo(20d);
        assertThat(result.measurements().get(Duration.ofMinutes(5)).errorCount()).isEqualTo(1d);
        assertThat(result.measurements().get(Duration.ofHours(1)).requestCount()).isNull();
        assertThat(result.measurements().get(Duration.ofHours(1)).errorCount()).isNull();
    }

    @Test
    void rejectsUnknownCorrelationKeysAsOneProviderWideUnavailableFailure() {
        RequestOutcomeQueryService metrics = new RequestOutcomeQueryService(
                ignored -> {
                    throw new AssertionError("legacy scalar measurement must not be used");
                },
                ignored -> new RequestOutcomeBatchMeasurement(Map.of(
                        "PT5M", new io.geordi.metrics.application.RequestOutcomeMeasurement(20d, 1d),
                        "unexpected", new io.geordi.metrics.application.RequestOutcomeMeasurement(20d, 1d))));

        assertThatThrownBy(() -> new MetricsRequestOutcomeMeasurementAdapter(metrics).measureBounded(request()))
                .isInstanceOf(MetricsMeasurementUnavailableException.class);
    }

    @Test
    void translatesMetricsPortFailureToOneProviderWideUnavailableFailure() {
        RequestOutcomeQueryService metrics = new RequestOutcomeQueryService(
                ignored -> {
                    throw new AssertionError("legacy scalar measurement must not be used");
                },
                ignored -> {
                    throw new RequestOutcomeQueryException(
                            RequestOutcomeQueryException.Reason.INTEGRITY, "duplicate provider correlation key");
                });

        assertThatThrownBy(() -> new MetricsRequestOutcomeMeasurementAdapter(metrics).measureBounded(request()))
                .isInstanceOf(MetricsMeasurementUnavailableException.class);
    }

    private static BoundedRequestOutcomeMeasurementRequest request() {
        Map<Duration, TimeRange> ranges = new LinkedHashMap<>();
        ranges.put(Duration.ofMinutes(5), new TimeRange(NOW.minus(Duration.ofMinutes(5)), NOW));
        ranges.put(Duration.ofHours(1), new TimeRange(NOW.minus(Duration.ofHours(1)), NOW));
        return new BoundedRequestOutcomeMeasurementRequest(
                new ServiceIdentity("checkout", "commerce", "production"), ranges);
    }
}
