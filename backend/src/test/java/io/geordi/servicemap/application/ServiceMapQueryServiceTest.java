package io.geordi.servicemap.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.servicemap.application.port.out.TraceEvidencePort;
import io.geordi.servicemap.domain.CandidateTrace;
import io.geordi.servicemap.domain.CandidateTraceBatch;
import io.geordi.servicemap.domain.ServiceIdentity;
import io.geordi.servicemap.domain.SpanId;
import io.geordi.servicemap.domain.SpanKind;
import io.geordi.servicemap.domain.TelemetryOrigin;
import io.geordi.servicemap.domain.TimeRange;
import io.geordi.servicemap.domain.TraceEvidenceSpan;
import io.geordi.servicemap.domain.TraceId;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class ServiceMapQueryServiceTest {

    private static final Instant FROM = Instant.parse("2026-08-20T10:00:00Z");
    private static final Instant TO = Instant.parse("2026-08-20T11:00:00Z");
    private static final ServiceIdentity ORDERS = new ServiceIdentity("orders", "shop", "dev");
    private static final ServiceIdentity PAYMENTS = new ServiceIdentity("payments", null, "dev");

    @Test
    void derivesOnlyDirectMonitoredClientToServerEvidenceWithExactContext() {
        CandidateTrace qualifying = trace("00000000000000000000000000000001", List.of(
                span("0000000000000001", null, ORDERS, SpanKind.CLIENT, TelemetryOrigin.MONITORED, FROM),
                span("0000000000000002", "0000000000000001", PAYMENTS, SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, FROM.plusSeconds(1))));
        CandidateTrace coOccurrence = trace("00000000000000000000000000000002", List.of(
                span("0000000000000003", null, ORDERS, SpanKind.CLIENT, TelemetryOrigin.MONITORED, FROM),
                span("0000000000000004", null, PAYMENTS, SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, FROM.plusSeconds(2))));
        CandidateTrace wrongEnvironment = trace("00000000000000000000000000000003", List.of(
                span("0000000000000005", null, ORDERS, SpanKind.CLIENT, TelemetryOrigin.MONITORED, FROM),
                span("0000000000000006", "0000000000000005",
                        new ServiceIdentity("payments", null, "staging"), SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, FROM.plusSeconds(3))));

        var result = service(qualifying, coOccurrence, wrongEnvironment)
                .query(new ServiceMapQuery("dev", new TimeRange(FROM, TO)));

        assertThat(result.nodes()).containsExactly(ORDERS, PAYMENTS);
        assertThat(result.edges()).singleElement().satisfies(edge -> {
            assertThat(edge.caller()).isEqualTo(ORDERS);
            assertThat(edge.callee()).isEqualTo(PAYMENTS);
            assertThat(edge.evidenceCount()).isEqualTo(1);
            assertThat(edge.evidence()).singleElement().satisfies(evidence -> {
                assertThat(evidence.traceId().value()).endsWith("1");
                assertThat(evidence.observedAt()).isEqualTo(FROM.plusSeconds(1));
            });
        });
        assertThat(result.truncated()).isFalse();
    }

    @Test
    void deduplicatesEvidenceByTraceAndBoundsRepresentativesDeterministically() {
        List<CandidateTrace> traces = new ArrayList<>();
        for (int index = 1; index <= 4; index++) {
            String traceId = "%032x".formatted(index);
            traces.add(trace(traceId, List.of(
                    span("%016x".formatted(index * 2L), null, ORDERS, SpanKind.CLIENT,
                            TelemetryOrigin.MONITORED, FROM),
                    span("%016x".formatted(index * 2L + 1), "%016x".formatted(index * 2L), PAYMENTS,
                            SpanKind.SERVER, TelemetryOrigin.MONITORED, FROM.plusSeconds(index)),
                    span("%016x".formatted(index * 2L + 8), "%016x".formatted(index * 2L), PAYMENTS,
                            SpanKind.SERVER, TelemetryOrigin.MONITORED, FROM.plusSeconds(index + 10L)))));
        }

        var result = service(traces.toArray(CandidateTrace[]::new))
                .query(new ServiceMapQuery("dev", new TimeRange(FROM, TO)));

        assertThat(result.edges()).singleElement().satisfies(edge -> {
            assertThat(edge.evidenceCount()).isEqualTo(4);
            assertThat(edge.evidence()).hasSize(3);
            assertThat(edge.evidence()).extracting(item -> item.traceId().value())
                    .containsExactly("00000000000000000000000000000004",
                            "00000000000000000000000000000003",
                            "00000000000000000000000000000002");
            assertThat(edge.evidence()).extracting(item -> item.observedAt())
                    .containsExactly(FROM.plusSeconds(14), FROM.plusSeconds(13), FROM.plusSeconds(12));
        });
        assertThat(result.truncated()).isFalse();
    }

    @Test
    void marksProviderCandidateTruncationAndOmitsSelfPlatformUnclassifiedAndOutOfRangeEdges() {
        ServiceIdentity platform = new ServiceIdentity("geordi", null, "dev");
        CandidateTrace rejected = trace("00000000000000000000000000000009", List.of(
                span("0000000000000011", null, ORDERS, SpanKind.CLIENT, TelemetryOrigin.MONITORED, FROM),
                span("0000000000000012", "0000000000000011", ORDERS, SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, FROM.plusSeconds(1)),
                span("0000000000000013", "0000000000000011", platform, SpanKind.SERVER,
                        TelemetryOrigin.PLATFORM, FROM.plusSeconds(2)),
                span("0000000000000014", "0000000000000011", PAYMENTS, SpanKind.SERVER,
                        TelemetryOrigin.UNCLASSIFIED, FROM.plusSeconds(3)),
                span("0000000000000015", "0000000000000011", PAYMENTS, SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, TO)));
        TraceEvidencePort port = query -> new CandidateTraceBatch(List.of(rejected), true);

        var result = new ServiceMapQueryService(port)
                .query(new ServiceMapQuery("dev", new TimeRange(FROM, TO)));

        assertThat(result.nodes()).isEmpty();
        assertThat(result.edges()).isEmpty();
        assertThat(result.truncated()).isTrue();
    }

    @Test
    void enforcesTheDeterministicHundredEdgeGraphCap() {
        List<TraceEvidenceSpan> spans = new ArrayList<>();
        long identifier = 100;
        for (int callerIndex = 0; callerIndex < 11; callerIndex++) {
            ServiceIdentity caller = new ServiceIdentity("caller-%02d".formatted(callerIndex), null, "dev");
            for (int calleeIndex = 0; calleeIndex < 10; calleeIndex++) {
                ServiceIdentity callee = new ServiceIdentity("callee-%02d".formatted(calleeIndex), null, "dev");
                String clientId = "%016x".formatted(identifier++);
                spans.add(span(clientId, null, caller, SpanKind.CLIENT, TelemetryOrigin.MONITORED, FROM));
                spans.add(span("%016x".formatted(identifier++), clientId, callee, SpanKind.SERVER,
                        TelemetryOrigin.MONITORED, FROM.plusSeconds(calleeIndex + 1L)));
            }
        }

        var result = service(trace("00000000000000000000000000000010", spans))
                .query(new ServiceMapQuery("dev", new TimeRange(FROM, TO)));

        assertThat(result.nodes()).hasSize(20);
        assertThat(result.edges()).hasSize(100);
        assertThat(result.truncated()).isTrue();
    }

    private static ServiceMapQueryService service(CandidateTrace... traces) {
        return new ServiceMapQueryService(query -> new CandidateTraceBatch(List.of(traces), false));
    }

    private static CandidateTrace trace(String id, List<TraceEvidenceSpan> spans) {
        return new CandidateTrace(new TraceId(id), spans);
    }

    private static TraceEvidenceSpan span(
            String id,
            String parentId,
            ServiceIdentity service,
            SpanKind kind,
            TelemetryOrigin origin,
            Instant start) {
        return new TraceEvidenceSpan(
                new SpanId(id), parentId == null ? null : new SpanId(parentId), service, origin, kind, start);
    }
}
