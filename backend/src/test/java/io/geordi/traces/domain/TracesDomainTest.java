package io.geordi.traces.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;

class TracesDomainTest {

    private static final Instant NOW = Instant.parse("2026-08-13T12:00:00Z");
    private static final TraceId TRACE_ID = new TraceId("0123456789ABCDEF0123456789ABCDEF");
    private static final SpanService MONITORED = new SpanService(
            "orders", "shop", "dev", TelemetryOrigin.MONITORED);

    @Test
    void validatesAndCanonicalizesOpenTelemetryIdentifiers() {
        assertThat(TRACE_ID.value()).isEqualTo("0123456789abcdef0123456789abcdef");
        assertThat(new SpanId("0123456789ABCDEF").value()).isEqualTo("0123456789abcdef");

        assertThatThrownBy(() -> new TraceId("0".repeat(32))).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TraceId("abc")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new SpanId("0".repeat(16))).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new SpanId("xyzxyzxyzxyzxyzx")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void validatesHalfOpenBoundedRangesAndCompositeSearchIdentity() {
        TimeRange range = new TimeRange(NOW.minus(Duration.ofHours(6)), NOW);

        assertThat(range.contains(range.from())).isTrue();
        assertThat(range.contains(range.to())).isFalse();
        assertThat(new ServiceIdentity(" orders ", " ", " dev "))
                .isEqualTo(new ServiceIdentity("orders", null, "dev"));
        assertThatThrownBy(() -> new TimeRange(NOW, NOW)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TimeRange(NOW.minus(Duration.ofHours(6)).minusNanos(1), NOW))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new ServiceIdentity("orders", null, " "))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void createsAStableHierarchyWithNanosecondOffsetsAndMixedResources() {
        TraceSpan childLater = span("0000000000000003", "0000000000000001", "child-later",
                NOW.plusNanos(30), 10, MONITORED, SpanStatus.ERROR);
        TraceSpan root = span("0000000000000001", null, "root", NOW, 100,
                MONITORED, SpanStatus.UNSET);
        TraceSpan externalChild = span("0000000000000002", "0000000000000001", "external",
                NOW.plusNanos(10), 20,
                new SpanService("payment", null, null, TelemetryOrigin.UNCLASSIFIED), SpanStatus.OK);

        TraceDetail detail = new TraceDetail(TRACE_ID, List.of(childLater, root, externalChild));

        assertThat(detail.startTime()).isEqualTo(NOW);
        assertThat(detail.duration()).isEqualTo(Duration.ofNanos(100));
        assertThat(detail.error()).isTrue();
        assertThat(detail.hasMonitoredSpan()).isTrue();
        assertThat(detail.spans()).extracting(node -> node.span().name())
                .containsExactly("root", "external", "child-later");
        assertThat(detail.spans()).extracting(TraceSpanNode::depth).containsExactly(0, 1, 1);
        assertThat(detail.spans()).extracting(TraceSpanNode::startOffsetNanos).containsExactly(0L, 10L, 30L);
    }

    @Test
    void retainsOrphansButRejectsDuplicateAndCyclicRelationships() {
        TraceSpan orphan = span("0000000000000002", "0000000000000099", "orphan", NOW, 1,
                MONITORED, SpanStatus.UNSET);
        assertThat(new TraceDetail(TRACE_ID, List.of(orphan)).spans().getFirst().depth()).isZero();

        TraceSpan duplicate = span("0000000000000002", null, "duplicate", NOW, 1,
                MONITORED, SpanStatus.UNSET);
        assertThatThrownBy(() -> new TraceDetail(TRACE_ID, List.of(orphan, duplicate)))
                .isInstanceOf(IllegalArgumentException.class);

        TraceSpan first = span("0000000000000003", "0000000000000004", "first", NOW, 1,
                MONITORED, SpanStatus.UNSET);
        TraceSpan second = span("0000000000000004", "0000000000000003", "second", NOW, 1,
                MONITORED, SpanStatus.UNSET);
        assertThatThrownBy(() -> new TraceDetail(TRACE_ID, List.of(first, second)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void followsOpenTelemetryStatusPrecedenceAndOnlyFailsATraceForMonitoredSpans() {
        HttpMetadata server500 = new HttpMetadata(null, null, null, 500, null, null);
        TraceSpan explicitOk = span("0000000000000005", null, "ok", NOW, 1,
                MONITORED, SpanKind.SERVER, SpanStatus.OK, "500", server500);
        assertThat(explicitOk.error()).isFalse();

        TraceSpan inferredServerError = span("0000000000000006", null, "server", NOW, 1,
                MONITORED, SpanKind.SERVER, SpanStatus.UNSET, null, server500);
        assertThat(inferredServerError.error()).isTrue();

        TraceSpan platformError = span("0000000000000007", null, "platform", NOW, 1,
                new SpanService("geordi", null, "dev", TelemetryOrigin.PLATFORM),
                SpanKind.INTERNAL, SpanStatus.ERROR, null, null);
        TraceSpan monitoredOk = span("0000000000000008", null, "monitored", NOW, 1,
                MONITORED, SpanKind.INTERNAL, SpanStatus.OK, null, null);
        assertThat(new TraceDetail(TRACE_ID, List.of(platformError, monitoredOk)).error()).isFalse();
    }

    private static TraceSpan span(
            String spanId,
            String parentId,
            String name,
            Instant start,
            long durationNanos,
            SpanService service,
            SpanStatus status) {
        return new TraceSpan(
                TRACE_ID,
                new SpanId(spanId),
                parentId == null ? null : new SpanId(parentId),
                name,
                service,
                SpanKind.INTERNAL,
                status,
                start,
                Duration.ofNanos(durationNanos),
                null,
                null);
    }

    private static TraceSpan span(
            String spanId,
            String parentId,
            String name,
            Instant start,
            long durationNanos,
            SpanService service,
            SpanKind kind,
            SpanStatus status,
            String errorType,
            HttpMetadata http) {
        return new TraceSpan(
                TRACE_ID,
                new SpanId(spanId),
                parentId == null ? null : new SpanId(parentId),
                name,
                service,
                kind,
                status,
                start,
                Duration.ofNanos(durationNanos),
                errorType,
                http);
    }
}
