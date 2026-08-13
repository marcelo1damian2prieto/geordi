package io.geordi.traces.application;

import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public final class TraceQueryService {

    private static final Comparator<ServiceIdentity> SERVICE_ORDER = Comparator.comparing(ServiceIdentity::name)
            .thenComparing(service -> Objects.toString(service.namespace(), ""))
            .thenComparing(ServiceIdentity::environment);
    private static final Comparator<TraceSummary> TRACE_ORDER = Comparator.comparing(TraceSummary::startTime)
            .reversed()
            .thenComparing(summary -> summary.traceId().value());

    private final TraceQueryPort port;

    public TraceQueryService(TraceQueryPort port) {
        this.port = Objects.requireNonNull(port, "trace query port must not be null");
    }

    public List<ServiceIdentity> services(TimeRange range) {
        return port.findServices(range).stream().distinct().sorted(SERVICE_ORDER).toList();
    }

    public List<TraceSummary> search(TraceSearchCriteria criteria) {
        return port.search(criteria).stream()
                .filter(summary -> criteria.range().contains(summary.startTime()))
                .sorted(TRACE_ORDER)
                .limit(criteria.limit())
                .toList();
    }

    public TraceDetail trace(TraceId traceId) {
        TraceDetail detail = port.findTrace(traceId)
                .filter(TraceDetail::hasMonitoredSpan)
                .orElseThrow(() -> new TraceNotFoundException(traceId));
        return detail;
    }
}
