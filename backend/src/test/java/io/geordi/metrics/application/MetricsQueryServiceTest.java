package io.geordi.metrics.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;

class MetricsQueryServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-13T12:00:00Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders", "shop", "dev");
    private static final TimeRange RANGE = new TimeRange(NOW.minusSeconds(900), NOW);

    @Test
    void overviewQueriesTheClosedCatalogAndOmitsMissingValuesRatherThanInventingZero() {
        RecordingPort port = new RecordingPort();
        port.result = List.of(
                new MetricSeries(OperationalMetric.JVM_MEMORY_USED,
                        List.of(new MetricPoint(NOW.minusSeconds(1), 42))),
                new MetricSeries(OperationalMetric.JVM_CPU_UTILIZATION, List.of()));

        MetricsOverview result = new MetricsQueryService(port).overview(SERVICE, RANGE);

        assertThat(port.lastQuery.metrics()).containsExactlyInAnyOrder(OperationalMetric.values());
        assertThat(result.values()).singleElement().satisfies(value -> {
            assertThat(value.metric()).isEqualTo(OperationalMetric.JVM_MEMORY_USED);
            assertThat(value.unit()).isEqualTo("By");
            assertThat(value.point().value()).isEqualTo(42);
        });
    }

    @Test
    void serviceDiscoveryIsDeduplicatedAndDeterministicallyOrdered() {
        RecordingPort port = new RecordingPort();
        port.services = List.of(
                new ServiceIdentity("zeta", null, "dev"),
                new ServiceIdentity("alpha", null, "dev"),
                new ServiceIdentity("alpha", null, "dev"));

        assertThat(new MetricsQueryService(port).services(RANGE)).extracting(ServiceIdentity::name)
                .containsExactly("alpha", "zeta");
    }

    @Test
    void resultSeriesAreHardLimitedToThreeHundredOrderedPoints() {
        RecordingPort port = new RecordingPort();
        port.result = List.of(new MetricSeries(OperationalMetric.JVM_THREAD_COUNT,
                IntStream.range(0, 600)
                        .mapToObj(index -> new MetricPoint(NOW.minusSeconds(600L - index), index))
                        .toList()));

        MetricSeries result = new MetricsQueryService(port).series(
                SERVICE, RANGE, List.of(OperationalMetric.JVM_THREAD_COUNT)).getFirst();

        assertThat(result.points()).hasSize(300);
        assertThat(result.points().getFirst().value()).isZero();
        assertThat(result.points().getLast().value()).isEqualTo(599);
    }

    private static final class RecordingPort implements MetricsQueryPort {
        private List<ServiceIdentity> services = List.of();
        private List<MetricSeries> result = new ArrayList<>();
        private MetricsQuery lastQuery;

        @Override
        public List<ServiceIdentity> findServices(TimeRange range) {
            return services;
        }

        @Override
        public List<MetricSeries> query(MetricsQuery query) {
            lastQuery = query;
            return result;
        }
    }
}
