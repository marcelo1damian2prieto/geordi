package io.geordi.logs.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TimeRange;
import io.geordi.logs.domain.TraceId;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;
import org.junit.jupiter.api.Test;

class LogsQueryServiceTest {

    private static final Instant NOW = Instant.parse("2026-08-14T12:00:00Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders", "shop", "dev");
    private static final TimeRange RANGE = new TimeRange(NOW.minusSeconds(900), NOW);
    private static final TraceId TRACE_ID = new TraceId("0123456789abcdef0123456789abcdef");
    private static final SpanId SPAN_ID = new SpanId("0123456789abcdef");

    @Test
    void validatesBoundedSearchCriteria() {
        assertThat(new LogSearchCriteria(SERVICE, RANGE, null, "  needle  ", null, null, 100).text())
                .isEqualTo("needle");
        assertThatThrownBy(() -> new LogSearchCriteria(SERVICE, RANGE, null, "x".repeat(257), null, null, 100))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new LogSearchCriteria(SERVICE, RANGE, null, null, null, SPAN_ID, 100))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new LogSearchCriteria(SERVICE, RANGE, null, null, null, null, 201))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void serviceDiscoveryIsExactDeduplicatedOrderedAndBounded() {
        RecordingPort port = new RecordingPort();
        port.services = new ArrayList<>(IntStream.range(0, 205)
                .mapToObj(index -> new ServiceIdentity("service-%03d".formatted(index), null, "dev"))
                .toList());
        port.services.add(port.services.getFirst());

        List<ServiceIdentity> result = new LogsQueryService(port).services(RANGE);

        assertThat(result).hasSize(200).isSortedAccordingTo(java.util.Comparator.comparing(ServiceIdentity::name));
    }

    @Test
    void appliesEveryFilterAndReturnsDeterministicNewestFirstBoundedResults() {
        RecordingPort port = new RecordingPort();
        port.logs = List.of(
                log(NOW.minusSeconds(3), LogSeverity.ERROR, "needle older", TRACE_ID, SPAN_ID),
                log(NOW.minusSeconds(1), LogSeverity.ERROR, "needle newest", TRACE_ID, SPAN_ID),
                log(NOW.minusSeconds(2), LogSeverity.INFO, "needle ignored", TRACE_ID, SPAN_ID),
                log(RANGE.to(), LogSeverity.ERROR, "needle boundary", TRACE_ID, SPAN_ID));
        LogSearchCriteria criteria = new LogSearchCriteria(
                SERVICE, RANGE, LogSeverity.ERROR, "needle", TRACE_ID, SPAN_ID, 1);

        assertThat(new LogsQueryService(port).search(criteria))
                .extracting(LogRecord::body)
                .containsExactly("needle newest");
    }

    @Test
    void rejectsProviderCrossServiceContamination() {
        RecordingPort port = new RecordingPort();
        port.logs = List.of(new LogRecord(
                NOW.minusSeconds(1), null, LogSeverity.INFO, "INFO", "body",
                new ServiceIdentity("payments", "shop", "dev"), null, null, Map.of()));

        assertThatThrownBy(() -> new LogsQueryService(port).search(
                new LogSearchCriteria(SERVICE, RANGE, null, null, null, null, 100)))
                .isInstanceOf(LogsBackendException.class)
                .extracting(error -> ((LogsBackendException) error).reason())
                .isEqualTo(LogsBackendException.Reason.MALFORMED_RESPONSE);
    }

    private static LogRecord log(
            Instant timestamp, LogSeverity severity, String body, TraceId traceId, SpanId spanId) {
        return new LogRecord(timestamp, null, severity, severity.name(), body, SERVICE, traceId, spanId, Map.of());
    }

    private static final class RecordingPort implements LogsQueryPort {
        private List<ServiceIdentity> services = List.of();
        private List<LogRecord> logs = List.of();

        @Override
        public List<ServiceIdentity> findServices(TimeRange range) {
            return services;
        }

        @Override
        public List<LogRecord> search(LogSearchCriteria criteria) {
            return logs;
        }
    }
}
