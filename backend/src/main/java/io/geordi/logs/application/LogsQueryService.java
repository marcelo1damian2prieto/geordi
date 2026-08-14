package io.geordi.logs.application;

import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public final class LogsQueryService {

    private static final int SERVICE_LIMIT = 200;
    private static final Comparator<ServiceIdentity> SERVICE_ORDER = Comparator.comparing(ServiceIdentity::name)
            .thenComparing(service -> Objects.toString(service.namespace(), ""))
            .thenComparing(ServiceIdentity::environment);
    private static final Comparator<LogRecord> LOG_ORDER = Comparator.comparing(LogRecord::timestamp).reversed()
            .thenComparing(record -> optional(record.traceId() == null ? null : record.traceId().value()))
            .thenComparing(record -> optional(record.spanId() == null ? null : record.spanId().value()))
            .thenComparing(record -> record.severity().name())
            .thenComparing(LogRecord::body)
            .thenComparing(record -> record.attributes().toString());

    private final LogsQueryPort port;

    public LogsQueryService(LogsQueryPort port) {
        this.port = Objects.requireNonNull(port, "logs query port must not be null");
    }

    public List<ServiceIdentity> services(TimeRange range) {
        return port.findServices(range).stream()
                .distinct()
                .sorted(SERVICE_ORDER)
                .limit(SERVICE_LIMIT)
                .toList();
    }

    public List<LogRecord> search(LogSearchCriteria criteria) {
        List<LogRecord> records = port.search(criteria);
        for (LogRecord record : records) {
            if (!criteria.service().equals(record.service())) {
                throw new LogsBackendException(
                        LogsBackendException.Reason.MALFORMED_RESPONSE,
                        "Log storage returned a record for a different service identity");
            }
        }
        return records.stream()
                .filter(record -> criteria.range().contains(record.timestamp()))
                .filter(record -> criteria.severity() == null || criteria.severity() == record.severity())
                .filter(record -> criteria.text() == null || record.body().contains(criteria.text()))
                .filter(record -> criteria.traceId() == null || criteria.traceId().equals(record.traceId()))
                .filter(record -> criteria.spanId() == null || criteria.spanId().equals(record.spanId()))
                .sorted(LOG_ORDER)
                .limit(criteria.limit())
                .toList();
    }

    private static String optional(String value) {
        return value == null ? "" : value;
    }
}
