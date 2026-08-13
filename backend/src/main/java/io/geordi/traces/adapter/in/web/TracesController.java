package io.geordi.traces.adapter.in.web;

import io.geordi.traces.application.TraceQueryService;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.domain.HttpMetadata;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.SpanService;
import io.geordi.traces.domain.TelemetryOrigin;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSpan;
import io.geordi.traces.domain.TraceSpanNode;
import io.geordi.traces.domain.TraceSummary;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnProperty(
        prefix = "geordi.modules.traces", name = "enabled", havingValue = "true", matchIfMissing = true)
@RequestMapping("/api/traces")
public class TracesController {

    private final TraceQueryService service;

    public TracesController(TraceQueryService service) {
        this.service = service;
    }

    @GetMapping("/services")
    public ServicesResponse services(
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant to) {
        return new ServicesResponse(service.services(new TimeRange(from, to)));
    }

    @GetMapping
    public SearchResponse search(
            @RequestParam String serviceName,
            @RequestParam(required = false) String serviceNamespace,
            @RequestParam String environment,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant to,
            @RequestParam(defaultValue = "false") boolean errorOnly) {
        ServiceIdentity identity = new ServiceIdentity(serviceName, serviceNamespace, environment);
        TimeRange range = new TimeRange(from, to);
        TraceSearchCriteria criteria = new TraceSearchCriteria(identity, range, errorOnly);
        return new SearchResponse(
                identity,
                new RangeResponse(range.from().toString(), range.to().toString()),
                service.search(criteria).stream().map(TraceSummaryResponse::from).toList());
    }

    @GetMapping("/{traceId}")
    public TraceDetailResponse detail(@PathVariable String traceId) {
        return TraceDetailResponse.from(service.trace(new TraceId(traceId)));
    }

    public record ServicesResponse(List<ServiceIdentity> services) {
    }

    public record SearchResponse(
            ServiceIdentity service, RangeResponse range, List<TraceSummaryResponse> traces) {
    }

    public record RangeResponse(String from, String to) {
    }

    public record TraceSummaryResponse(
            String traceId,
            String rootSpanName,
            String startTime,
            long durationNanos,
            int spanCount,
            boolean error) {

        static TraceSummaryResponse from(TraceSummary summary) {
            return new TraceSummaryResponse(
                    summary.traceId().value(),
                    summary.rootSpanName(),
                    summary.startTime().toString(),
                    summary.duration().toNanos(),
                    summary.spanCount(),
                    summary.error());
        }
    }

    public record TraceDetailResponse(
            String traceId,
            String startTime,
            long durationNanos,
            int spanCount,
            boolean error,
            List<SpanResponse> spans) {

        static TraceDetailResponse from(TraceDetail detail) {
            return new TraceDetailResponse(
                    detail.traceId().value(),
                    detail.startTime().toString(),
                    detail.duration().toNanos(),
                    detail.spanCount(),
                    detail.error(),
                    detail.spans().stream().map(SpanResponse::from).toList());
        }
    }

    public record SpanResponse(
            String traceId,
            String spanId,
            String parentSpanId,
            String name,
            SpanServiceResponse service,
            String telemetryOrigin,
            String kind,
            String status,
            String startTime,
            long startOffsetNanos,
            long durationNanos,
            boolean error,
            String errorType,
            HttpResponse http) {

        static SpanResponse from(TraceSpanNode node) {
            TraceSpan span = node.span();
            return new SpanResponse(
                    span.traceId().value(),
                    span.spanId().value(),
                    span.parentSpanId() == null ? null : span.parentSpanId().value(),
                    span.name(),
                    SpanServiceResponse.from(span.service()),
                    origin(span.service().telemetryOrigin()),
                    span.kind().name(),
                    span.status().name(),
                    span.startTime().toString(),
                    node.startOffsetNanos(),
                    span.duration().toNanos(),
                    span.error(),
                    span.errorType(),
                    HttpResponse.from(span.http()));
        }

        private static String origin(TelemetryOrigin origin) {
            return origin == TelemetryOrigin.UNCLASSIFIED ? null : origin.name().toLowerCase(Locale.ROOT);
        }
    }

    public record SpanServiceResponse(String name, String namespace, String environment) {

        static SpanServiceResponse from(SpanService service) {
            return new SpanServiceResponse(service.name(), service.namespace(), service.environment());
        }
    }

    public record HttpResponse(
            String requestMethod,
            String route,
            String path,
            Integer responseStatusCode,
            String serverAddress,
            Integer serverPort) {

        static HttpResponse from(HttpMetadata metadata) {
            return metadata == null ? null : new HttpResponse(
                    metadata.requestMethod(),
                    metadata.route(),
                    metadata.path(),
                    metadata.responseStatusCode(),
                    metadata.serverAddress(),
                    metadata.serverPort());
        }
    }
}
