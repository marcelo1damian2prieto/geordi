package io.geordi.traces.application;

import io.geordi.traces.domain.SpanId;
import io.geordi.traces.domain.SpanKind;
import io.geordi.traces.domain.SpanService;
import io.geordi.traces.domain.SpanStatus;
import io.geordi.traces.domain.TelemetryOrigin;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSpan;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

final class TraceFixtures {

    private TraceFixtures() {
    }

    static TraceDetail platformOnlyDetail(TraceId traceId, Instant start) {
        TraceSpan span = new TraceSpan(
                traceId,
                new SpanId("0123456789abcdef"),
                null,
                "platform",
                new SpanService("geordi-backend", "geordi", "dev", TelemetryOrigin.PLATFORM),
                SpanKind.SERVER,
                SpanStatus.UNSET,
                start,
                Duration.ofMillis(1),
                null,
                null);
        return new TraceDetail(traceId, List.of(span));
    }
}
