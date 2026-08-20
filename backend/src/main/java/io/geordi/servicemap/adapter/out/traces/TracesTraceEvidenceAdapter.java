package io.geordi.servicemap.adapter.out.traces;

import io.geordi.servicemap.application.ServiceMapBackendException;
import io.geordi.servicemap.application.ServiceMapQuery;
import io.geordi.servicemap.application.port.out.TraceEvidencePort;
import io.geordi.servicemap.domain.CandidateTrace;
import io.geordi.servicemap.domain.CandidateTraceBatch;
import io.geordi.servicemap.domain.ServiceIdentity;
import io.geordi.servicemap.domain.SpanId;
import io.geordi.servicemap.domain.SpanKind;
import io.geordi.servicemap.domain.TelemetryOrigin;
import io.geordi.servicemap.domain.TraceEvidenceSpan;
import io.geordi.servicemap.domain.TraceId;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceDependencyQuery;
import io.geordi.traces.application.TraceDependencyQueryService;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceSpan;
import java.util.List;
import java.util.Objects;

public final class TracesTraceEvidenceAdapter implements TraceEvidencePort {

    private final TraceDependencyQueryService traces;

    public TracesTraceEvidenceAdapter(TraceDependencyQueryService traces) {
        this.traces = Objects.requireNonNull(traces, "trace dependency service must not be null");
    }

    @Override
    public CandidateTraceBatch findCandidates(ServiceMapQuery query) {
        try {
            var traceQuery = new TraceDependencyQuery(
                    query.environment(),
                    new io.geordi.traces.domain.TimeRange(query.range().from(), query.range().to()));
            var result = traces.findCandidates(traceQuery);
            return new CandidateTraceBatch(
                    result.traces().stream().map(TracesTraceEvidenceAdapter::candidate).toList(),
                    result.truncated());
        } catch (TraceBackendException exception) {
            throw new ServiceMapBackendException(
                    ServiceMapBackendException.Reason.valueOf(exception.reason().name()),
                    "Trace storage could not supply service map evidence",
                    exception);
        }
    }

    private static CandidateTrace candidate(TraceDetail detail) {
        List<TraceEvidenceSpan> spans = detail.spans().stream()
                .map(io.geordi.traces.domain.TraceSpanNode::span)
                .filter(TracesTraceEvidenceAdapter::hasCompleteIdentity)
                .map(TracesTraceEvidenceAdapter::span)
                .toList();
        return new CandidateTrace(new TraceId(detail.traceId().value()), spans);
    }

    private static boolean hasCompleteIdentity(TraceSpan span) {
        return span.service().name() != null && span.service().environment() != null;
    }

    private static TraceEvidenceSpan span(TraceSpan span) {
        return new TraceEvidenceSpan(
                new SpanId(span.spanId().value()),
                span.parentSpanId() == null ? null : new SpanId(span.parentSpanId().value()),
                new ServiceIdentity(
                        span.service().name(), span.service().namespace(), span.service().environment()),
                TelemetryOrigin.valueOf(span.service().telemetryOrigin().name()),
                SpanKind.valueOf(span.kind().name()),
                span.startTime());
    }
}
