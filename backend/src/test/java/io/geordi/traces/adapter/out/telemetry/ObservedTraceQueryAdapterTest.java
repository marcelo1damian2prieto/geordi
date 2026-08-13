package io.geordi.traces.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.port.out.TraceBackendProbe;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class ObservedTraceQueryAdapterTest {

    @Test
    void preservesQueryResultsAndTurnsProbeExceptionsIntoDown() {
        ServiceIdentity identity = new ServiceIdentity("orders", "shop", "dev");
        TraceQueryPort query = new TraceQueryPort() {
            @Override
            public List<ServiceIdentity> findServices(TimeRange range) {
                return List.of(identity);
            }

            @Override
            public List<TraceSummary> search(TraceSearchCriteria criteria) {
                return List.of();
            }

            @Override
            public Optional<TraceDetail> findTrace(TraceId traceId) {
                return Optional.empty();
            }
        };
        TraceBackendProbe failingProbe = () -> {
            throw new IllegalStateException("provider details");
        };
        ObservedTraceQueryAdapter adapter = new ObservedTraceQueryAdapter(query, failingProbe);
        TimeRange range = new TimeRange(
                Instant.parse("2026-08-13T11:45:00Z"), Instant.parse("2026-08-13T12:00:00Z"));

        assertThat(adapter.findServices(range)).containsExactly(identity);
        assertThat(adapter.isQueryable()).isFalse();
    }
}
