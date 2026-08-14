package io.geordi.logs.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

class LogsDomainTest {

    private static final Instant NOW = Instant.parse("2026-08-14T12:00:00Z");

    @Test
    void validatesCanonicalIdentityRangeAndCorrelationIdentifiers() {
        TimeRange range = new TimeRange(NOW.minus(Duration.ofHours(6)), NOW);

        assertThat(range.contains(range.from())).isTrue();
        assertThat(range.contains(range.to())).isFalse();
        assertThat(new ServiceIdentity(" orders ", " ", " dev "))
                .isEqualTo(new ServiceIdentity("orders", null, "dev"));
        assertThat(new TraceId("0123456789ABCDEF0123456789ABCDEF").value())
                .isEqualTo("0123456789abcdef0123456789abcdef");
        assertThat(new SpanId("0123456789ABCDEF").value()).isEqualTo("0123456789abcdef");

        assertThatThrownBy(() -> new TimeRange(NOW, NOW)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TimeRange(NOW.minus(Duration.ofHours(6)).minusNanos(1), NOW))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TraceId("0".repeat(32))).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new SpanId("invalid" )).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void mapsOpenTelemetrySeverityGroupsAndPreservesUnknownText() {
        assertThat(LogSeverity.from(null, null)).isEqualTo(LogSeverity.UNSPECIFIED);
        assertThat(LogSeverity.from(0, "UNKNOWN")).isEqualTo(LogSeverity.UNSPECIFIED);
        assertThat(LogSeverity.from(1, null)).isEqualTo(LogSeverity.TRACE);
        assertThat(LogSeverity.from(8, null)).isEqualTo(LogSeverity.DEBUG);
        assertThat(LogSeverity.from(9, null)).isEqualTo(LogSeverity.INFO);
        assertThat(LogSeverity.from(16, null)).isEqualTo(LogSeverity.WARN);
        assertThat(LogSeverity.from(17, null)).isEqualTo(LogSeverity.ERROR);
        assertThat(LogSeverity.from(24, null)).isEqualTo(LogSeverity.FATAL);
        assertThat(LogSeverity.from(null, "warn2")).isEqualTo(LogSeverity.WARN);
        assertThatThrownBy(() -> LogSeverity.from(25, null)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void logRecordRequiresTraceForSpanAndCopiesAttributesDeterministically() {
        Map<String, String> attributes = new LinkedHashMap<>();
        attributes.put("z", "last");
        attributes.put("a", "first");
        LogRecord record = new LogRecord(
                NOW, null, LogSeverity.INFO, " INFO ", null,
                new ServiceIdentity("orders", null, "dev"), null, null, attributes);

        attributes.put("later", "mutation");
        assertThat(record.body()).isEmpty();
        assertThat(record.severityText()).isEqualTo("INFO");
        assertThat(record.attributes()).containsExactly(
                Map.entry("a", "first"), Map.entry("z", "last"));
        assertThatThrownBy(() -> new LogRecord(
                NOW, null, LogSeverity.INFO, null, "body",
                new ServiceIdentity("orders", null, "dev"), null,
                new SpanId("0123456789abcdef"), Map.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
