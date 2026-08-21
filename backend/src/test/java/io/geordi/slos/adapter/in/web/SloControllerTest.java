package io.geordi.slos.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.slos.application.RequestOutcomeMeasurement;
import io.geordi.slos.application.SloEvaluationService;
import io.geordi.slos.application.SloQueryService;
import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class SloControllerTest {

    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        SloDefinition definition = new SloDefinition(
                "checkout-availability", "Checkout availability", null,
                new ServiceIdentity("checkout", "commerce", "production"),
                SliType.AVAILABILITY, new BigDecimal("0.999"), EvaluationWindow.PT5M, true);
        SloDefinitionCatalog catalog = new SloDefinitionCatalog() {
            @Override
            public List<SloDefinition> findAll() {
                return List.of(definition);
            }

            @Override
            public Optional<SloDefinition> findById(String id) {
                return definition.id().equals(id) ? Optional.of(definition) : Optional.empty();
            }
        };
        var queryService = new SloQueryService(catalog);
        var evaluationService = new SloEvaluationService(
                catalog, ignored -> new RequestOutcomeMeasurement(1000d, 1d),
                Clock.fixed(Instant.parse("2026-08-20T18:00:00Z"), ZoneOffset.UTC));
        mvc = MockMvcBuilders.standaloneSetup(new SloController(queryService, evaluationService))
                .setControllerAdvice(new SloExceptionHandler()).build();
    }

    @Test
    void exposesListDetailAndExplainableEvaluationWithoutProviderSyntax() throws Exception {
        mvc.perform(get("/api/slos"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.slos[0].id").value("checkout-availability"))
                .andExpect(jsonPath("$.slos[0].service.namespace").value("commerce"))
                .andExpect(jsonPath("$.slos[0].target").value(0.999));
        mvc.perform(get("/api/slos/checkout-availability"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.window").value("PT5M"));
        mvc.perform(get("/api/slos/checkout-availability/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("MET"))
                .andExpect(jsonPath("$.observedValue").value(0.999))
                .andExpect(jsonPath("$.requestCount").value(1000))
                .andExpect(jsonPath("$.range.from").value("2026-08-20T17:55:00Z"))
                .andExpect(jsonPath("$.reason").doesNotExist());
    }

    @Test
    void returnsProblemDetailForUnknownDefinition() throws Exception {
        mvc.perform(get("/api/slos/missing"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.title").value("SLO not found"));
    }
}
