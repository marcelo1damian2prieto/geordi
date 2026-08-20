package io.geordi.servicemap.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.servicemap.application.ServiceMapBackendException;
import io.geordi.servicemap.application.ServiceMapUseCase;
import io.geordi.servicemap.domain.DependencyEvidence;
import io.geordi.servicemap.domain.ObservedDependency;
import io.geordi.servicemap.domain.ServiceIdentity;
import io.geordi.servicemap.domain.ServiceMapResult;
import io.geordi.servicemap.domain.TraceId;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class ServiceMapControllerTest {

    private static final Instant FROM = Instant.parse("2026-08-20T10:00:00Z");

    @Test
    void exposesCanonicalContextNodesEdgesEvidenceAndTruncation() throws Exception {
        ServiceIdentity caller = new ServiceIdentity("orders", "shop", "dev");
        ServiceIdentity callee = new ServiceIdentity("payments", null, "dev");
        ServiceMapUseCase service = query -> new ServiceMapResult(
                query.environment(), query.range(), List.of(caller, callee),
                List.of(new ObservedDependency(caller, callee, 2, List.of(new DependencyEvidence(
                        new TraceId("0123456789abcdef0123456789abcdef"), FROM.plusSeconds(1))))), true);

        mvc(service).perform(get("/api/service-map")
                        .param("environment", "dev")
                        .param("from", "2026-08-20T07:00:00-03:00")
                        .param("to", "2026-08-20T08:00:00-03:00"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.context.environment").value("dev"))
                .andExpect(jsonPath("$.context.range.from").value("2026-08-20T10:00:00Z"))
                .andExpect(jsonPath("$.nodes[0].namespace").value("shop"))
                .andExpect(jsonPath("$.nodes[1].namespace").doesNotExist())
                .andExpect(jsonPath("$.edges[0].caller.name").value("orders"))
                .andExpect(jsonPath("$.edges[0].callee.name").value("payments"))
                .andExpect(jsonPath("$.edges[0].evidenceCount").value(2))
                .andExpect(jsonPath("$.edges[0].evidence[0].traceId")
                        .value("0123456789abcdef0123456789abcdef"))
                .andExpect(jsonPath("$.truncated").value(true));
    }

    @Test
    void requiresExplicitOffsetAndMapsProviderFailuresWithoutDetails() throws Exception {
        MockMvc mvc = mvc(query -> {
            throw new ServiceMapBackendException(
                    ServiceMapBackendException.Reason.MALFORMED_RESPONSE, "secret Tempo payload");
        });

        mvc.perform(get("/api/service-map")
                        .param("environment", "dev")
                        .param("from", "2026-08-20T10:00:00")
                        .param("to", "2026-08-20T11:00:00Z"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").value("Invalid service map request"));

        mvc.perform(get("/api/service-map")
                        .param("environment", "dev")
                        .param("from", "2026-08-20T10:00:00Z")
                        .param("to", "2026-08-20T11:00:00Z"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.detail").value("Trace storage returned invalid service map evidence"));
    }

    private static MockMvc mvc(ServiceMapUseCase service) {
        return MockMvcBuilders.standaloneSetup(new ServiceMapController(service))
                .setControllerAdvice(new ServiceMapExceptionHandler()).build();
    }
}
