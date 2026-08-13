package io.geordi.traces.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;

class TraceQueryServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-13T12:00:00Z");
    private static final TimeRange RANGE = new TimeRange(NOW.minusSeconds(900), NOW);
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders", "shop", "dev");

    @Test
    void serviceDiscoveryIsDeduplicatedAndDeterministicallyOrdered() {
        RecordingPort port = new RecordingPort();
        port.services = List.of(
                new ServiceIdentity("zeta", null, "dev"),
                SERVICE,
                SERVICE,
                new ServiceIdentity("orders", "shop", "prod"));

        assertThat(new TraceQueryService(port).services(RANGE)).containsExactly(
                SERVICE,
                new ServiceIdentity("orders", "shop", "prod"),
                new ServiceIdentity("zeta", null, "dev"));
    }

    @Test
    void searchUsesTheFixedLimitAndReturnsOnlyTheHalfOpenRangeInStableOrder() {
        RecordingPort port = new RecordingPort();
        port.summaries = new ArrayList<>(IntStream.range(0, 55)
                .mapToObj(index -> summary(index, RANGE.from().plusSeconds(index + 1)))
                .toList());
        port.summaries.add(summary(100, RANGE.to()));

        TraceSearchCriteria criteria = new TraceSearchCriteria(SERVICE, RANGE, true);
        List<TraceSummary> result = new TraceQueryService(port).search(criteria);

        assertThat(criteria.limit()).isEqualTo(50);
        assertThat(result).hasSize(50);
        assertThat(result.getFirst().startTime()).isEqualTo(RANGE.from().plusSeconds(55));
        assertThat(result).allMatch(item -> RANGE.contains(item.startTime()));
    }

    @Test
    void hidesNonMonitoredTraceDetailsAsNotFound() {
        RecordingPort port = new RecordingPort();
        TraceId id = new TraceId("0123456789abcdef0123456789abcdef");
        port.detail = Optional.of(TraceFixtures.platformOnlyDetail(id, NOW));

        assertThatThrownBy(() -> new TraceQueryService(port).trace(id))
                .isInstanceOf(TraceNotFoundException.class);
    }

    private static TraceSummary summary(int index, Instant start) {
        return new TraceSummary(
                new TraceId("%032x".formatted(index + 1L)),
                "orders",
                "GET /orders",
                start,
                Duration.ofMillis(10),
                1,
                false);
    }

    private static final class RecordingPort implements TraceQueryPort {
        private List<ServiceIdentity> services = List.of();
        private List<TraceSummary> summaries = List.of();
        private Optional<TraceDetail> detail = Optional.empty();

        @Override
        public List<ServiceIdentity> findServices(TimeRange range) {
            return services;
        }

        @Override
        public List<TraceSummary> search(TraceSearchCriteria criteria) {
            return summaries;
        }

        @Override
        public Optional<TraceDetail> findTrace(TraceId traceId) {
            return detail;
        }
    }
}
