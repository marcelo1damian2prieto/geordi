package io.geordi.logs.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsBackendException;
import io.geordi.logs.application.LogsQueryService;
import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TimeRange;
import io.geordi.logs.domain.TraceId;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class LogsControllerTest {

    private static final Instant TIMESTAMP = Instant.parse("2026-08-14T11:59:59.123456789Z");
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders", "shop", "dev");
    private static final TraceId TRACE_ID = new TraceId("0123456789abcdef0123456789abcdef");
    private static final SpanId SPAN_ID = new SpanId("0123456789abcdef");

    private MutablePort port;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        port = new MutablePort();
        mvc = MockMvcBuilders.standaloneSetup(new LogsController(new LogsQueryService(port)))
                .setControllerAdvice(new LogsExceptionHandler())
                .build();
    }

    @Test
    void exposesVendorNeutralServiceAndLogContracts() throws Exception {
        port.services = List.of(SERVICE);
        port.logs = List.of(new LogRecord(
                TIMESTAMP,
                TIMESTAMP.plusNanos(1),
                LogSeverity.ERROR,
                "ERROR",
                "Payment failed",
                SERVICE,
                TRACE_ID,
                SPAN_ID,
                Map.of("scope_name", "checkout")));

        mvc.perform(get("/api/logs/services")
                        .param("from", "2026-08-14T11:45:00Z")
                        .param("to", "2026-08-14T12:00:00Z"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.services[0].name").value("orders"))
                .andExpect(jsonPath("$.services[0].namespace").value("shop"));

        mvc.perform(get("/api/logs")
                        .param("serviceName", "orders")
                        .param("serviceNamespace", "shop")
                        .param("environment", "dev")
                        .param("from", "2026-08-14T11:45:00Z")
                        .param("to", "2026-08-14T12:00:00Z")
                        .param("severity", "ERROR")
                        .param("text", "Payment")
                        .param("traceId", TRACE_ID.value())
                        .param("spanId", SPAN_ID.value()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service.name").value("orders"))
                .andExpect(jsonPath("$.range.from").value("2026-08-14T11:45:00Z"))
                .andExpect(jsonPath("$.logs[0].timestamp").value(TIMESTAMP.toString()))
                .andExpect(jsonPath("$.logs[0].observedTimestamp").value(TIMESTAMP.plusNanos(1).toString()))
                .andExpect(jsonPath("$.logs[0].severity").value("ERROR"))
                .andExpect(jsonPath("$.logs[0].severityText").value("ERROR"))
                .andExpect(jsonPath("$.logs[0].body").value("Payment failed"))
                .andExpect(jsonPath("$.logs[0].service.environment").value("dev"))
                .andExpect(jsonPath("$.logs[0].traceId").value(TRACE_ID.value()))
                .andExpect(jsonPath("$.logs[0].spanId").value(SPAN_ID.value()))
                .andExpect(jsonPath("$.logs[0].attributes.scope_name").value("checkout"))
                .andExpect(jsonPath("$.logs[0].severityNumber").doesNotExist());
    }

    @Test
    void rejectsInvalidBoundsAndCorrelationWithoutLeakingDetails() throws Exception {
        mvc.perform(get("/api/logs")
                        .param("serviceName", "orders")
                        .param("environment", "dev")
                        .param("from", "2026-08-14T11:45:00Z")
                        .param("to", "2026-08-14T12:00:00Z")
                        .param("spanId", SPAN_ID.value())
                        .param("limit", "201"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").value("Invalid logs request"));

        port.failure = new LogsBackendException(
                LogsBackendException.Reason.MALFORMED_RESPONSE, "secret Loki payload");
        mvc.perform(get("/api/logs/services")
                        .param("from", "2026-08-14T11:45:00Z")
                        .param("to", "2026-08-14T12:00:00Z"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.detail").value("Log storage returned invalid data"));
    }

    @Test
    void distinguishesUnavailableAndTimeoutFailures() throws Exception {
        port.failure = new LogsBackendException(LogsBackendException.Reason.UNAVAILABLE, "provider");
        performServices().andExpect(status().isServiceUnavailable());

        port.failure = new LogsBackendException(LogsBackendException.Reason.TIMEOUT, "provider");
        performServices().andExpect(status().isGatewayTimeout());
    }

    private org.springframework.test.web.servlet.ResultActions performServices() throws Exception {
        return mvc.perform(get("/api/logs/services")
                .param("from", "2026-08-14T11:45:00Z")
                .param("to", "2026-08-14T12:00:00Z"));
    }

    private static final class MutablePort implements LogsQueryPort {
        private List<ServiceIdentity> services = List.of();
        private List<LogRecord> logs = List.of();
        private RuntimeException failure;

        @Override
        public List<ServiceIdentity> findServices(TimeRange range) {
            failIfConfigured();
            return services;
        }

        @Override
        public List<LogRecord> search(LogSearchCriteria criteria) {
            failIfConfigured();
            return logs;
        }

        private void failIfConfigured() {
            if (failure != null) {
                throw failure;
            }
        }
    }
}
