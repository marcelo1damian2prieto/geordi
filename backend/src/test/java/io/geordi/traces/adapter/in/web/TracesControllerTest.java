package io.geordi.traces.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceQueryService;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.HttpMetadata;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.SpanId;
import io.geordi.traces.domain.SpanKind;
import io.geordi.traces.domain.SpanService;
import io.geordi.traces.domain.SpanStatus;
import io.geordi.traces.domain.TelemetryOrigin;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSpan;
import io.geordi.traces.domain.TraceSummary;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class TracesControllerTest {

    private static final Instant START = Instant.parse("2026-08-13T11:59:00Z");
    private static final TraceId TRACE_ID = new TraceId("0123456789abcdef0123456789abcdef");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders", "shop", "dev");

    private final MutablePort port = new MutablePort();
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        port.services = List.of(SERVICE);
        port.summaries = List.of(new TraceSummary(
                TRACE_ID, "orders", "GET /orders", START, Duration.ofNanos(50_000_000), 2, true));
        port.detail = Optional.of(detail());
        mvc = MockMvcBuilders.standaloneSetup(new TracesController(new TraceQueryService(port)))
                .setControllerAdvice(new TracesExceptionHandler())
                .build();
    }

    @Test
    void exposesServicesAndSearchWithTheExactCompositeContext() throws Exception {
        mvc.perform(get("/api/traces/services")
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.services[0].name").value("orders"))
                .andExpect(jsonPath("$.services[0].namespace").value("shop"))
                .andExpect(jsonPath("$.services[0].environment").value("dev"));

        mvc.perform(get("/api/traces")
                        .param("serviceName", "orders")
                        .param("serviceNamespace", "shop")
                        .param("environment", "dev")
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z")
                        .param("errorOnly", "true"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service.name").value("orders"))
                .andExpect(jsonPath("$.range.from").value("2026-08-13T11:45:00Z"))
                .andExpect(jsonPath("$.traces[0].traceId").value(TRACE_ID.value()))
                .andExpect(jsonPath("$.traces[0].rootSpanName").value("GET /orders"))
                .andExpect(jsonPath("$.traces[0].durationNanos").value(50_000_000))
                .andExpect(jsonPath("$.traces[0].spanCount").value(2))
                .andExpect(jsonPath("$.traces[0].error").value(true));
    }

    @Test
    void exposesCompleteDeterministicSpanDetailWithoutProviderJson() throws Exception {
        mvc.perform(get("/api/traces/{traceId}", TRACE_ID.value()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.traceId").value(TRACE_ID.value()))
                .andExpect(jsonPath("$.durationNanos").value(50_000_000))
                .andExpect(jsonPath("$.spanCount").value(2))
                .andExpect(jsonPath("$.error").value(true))
                .andExpect(jsonPath("$.spans[0].traceId").value(TRACE_ID.value()))
                .andExpect(jsonPath("$.spans[0].parentSpanId").doesNotExist())
                .andExpect(jsonPath("$.spans[0].telemetryOrigin").value("monitored"))
                .andExpect(jsonPath("$.spans[0].startOffsetNanos").value(0))
                .andExpect(jsonPath("$.spans[0].durationNanos").value(50_000_000))
                .andExpect(jsonPath("$.spans[0].error").value(true))
                .andExpect(jsonPath("$.spans[0].errorType").value("500"))
                .andExpect(jsonPath("$.spans[0].http.requestMethod").value("GET"))
                .andExpect(jsonPath("$.spans[0].http.responseStatusCode").value(500))
                .andExpect(jsonPath("$.spans[1].service.environment").doesNotExist())
                .andExpect(jsonPath("$.spans[1].telemetryOrigin").doesNotExist())
                .andExpect(jsonPath("$.spans[1].startOffsetNanos").value(10_000_000));
    }

    @Test
    void mapsInvalidNotFoundAndProviderFailuresWithoutLeakingDetails() throws Exception {
        mvc.perform(get("/api/traces/not-a-trace-id"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").value("Invalid traces request"));

        port.detail = Optional.empty();
        mvc.perform(get("/api/traces/{traceId}", TRACE_ID.value()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.detail").value("The requested trace was not found"));

        port.failure = new TraceBackendException(
                TraceBackendException.Reason.MALFORMED_RESPONSE, "secret provider response");
        mvc.perform(get("/api/traces/services")
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.detail").value("Trace storage returned invalid data"));
    }

    private static TraceDetail detail() {
        SpanId rootId = new SpanId("0123456789abcdef");
        TraceSpan root = new TraceSpan(
                TRACE_ID,
                rootId,
                null,
                "GET /orders",
                new SpanService("orders", "shop", "dev", TelemetryOrigin.MONITORED),
                SpanKind.SERVER,
                SpanStatus.ERROR,
                START,
                Duration.ofNanos(50_000_000),
                "500",
                new HttpMetadata("GET", "/orders", "/orders/42", 500, "orders.local", 8080));
        TraceSpan child = new TraceSpan(
                TRACE_ID,
                new SpanId("1123456789abcdef"),
                rootId,
                "external call",
                new SpanService("payment", null, null, TelemetryOrigin.UNCLASSIFIED),
                SpanKind.CLIENT,
                SpanStatus.OK,
                START.plusNanos(10_000_000),
                Duration.ofNanos(10_000_000),
                null,
                null);
        return new TraceDetail(TRACE_ID, List.of(child, root));
    }

    private static final class MutablePort implements TraceQueryPort {
        private List<ServiceIdentity> services = List.of();
        private List<TraceSummary> summaries = List.of();
        private Optional<TraceDetail> detail = Optional.empty();
        private RuntimeException failure;

        @Override
        public List<ServiceIdentity> findServices(TimeRange range) {
            failIfConfigured();
            return services;
        }

        @Override
        public List<TraceSummary> search(TraceSearchCriteria criteria) {
            failIfConfigured();
            return summaries;
        }

        @Override
        public Optional<TraceDetail> findTrace(TraceId traceId) {
            failIfConfigured();
            return detail;
        }

        private void failIfConfigured() {
            if (failure != null) {
                throw failure;
            }
        }
    }
}
