package io.geordi.logs.adapter.in.web;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsQueryService;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TimeRange;
import io.geordi.logs.domain.TraceId;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@ConditionalOnProperty(
        prefix = "geordi.modules.logs", name = "enabled", havingValue = "true", matchIfMissing = true)
@RequestMapping("/api/logs")
public class LogsController {

    private final LogsQueryService service;

    public LogsController(LogsQueryService service) {
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
            @RequestParam(required = false) LogSeverity severity,
            @RequestParam(required = false) String text,
            @RequestParam(required = false) String traceId,
            @RequestParam(required = false) String spanId,
            @RequestParam(defaultValue = "100") int limit) {
        ServiceIdentity identity = new ServiceIdentity(serviceName, serviceNamespace, environment);
        TimeRange range = new TimeRange(from, to);
        LogSearchCriteria criteria = new LogSearchCriteria(
                identity,
                range,
                severity,
                text,
                traceId == null ? null : new TraceId(traceId),
                spanId == null ? null : new SpanId(spanId),
                limit);
        return new SearchResponse(
                identity,
                new RangeResponse(range.from().toString(), range.to().toString()),
                service.search(criteria).stream().map(LogRecordResponse::from).toList());
    }

    public record ServicesResponse(List<ServiceIdentity> services) {
    }

    public record SearchResponse(
            ServiceIdentity service, RangeResponse range, List<LogRecordResponse> logs) {
    }

    public record RangeResponse(String from, String to) {
    }

    public record LogRecordResponse(
            String timestamp,
            String observedTimestamp,
            LogSeverity severity,
            String severityText,
            String body,
            ServiceIdentity service,
            String traceId,
            String spanId,
            Map<String, String> attributes) {

        static LogRecordResponse from(LogRecord record) {
            return new LogRecordResponse(
                    record.timestamp().toString(),
                    record.observedTimestamp() == null ? null : record.observedTimestamp().toString(),
                    record.severity(),
                    record.severityText(),
                    record.body(),
                    record.service(),
                    record.traceId() == null ? null : record.traceId().value(),
                    record.spanId() == null ? null : record.spanId().value(),
                    record.attributes());
        }
    }
}
