package io.geordi.slos.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
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
        SloDefinition definition = definition(SliType.AVAILABILITY, "0.999");
        mvc = mvc(definition, ignored -> new RequestOutcomeMeasurement(1000d, 1d));
    }

    private static MockMvc mvc(
            SloDefinition definition, io.geordi.slos.application.port.out.RequestOutcomeMeasurementPort port) {
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
                catalog, port,
                Clock.fixed(Instant.parse("2026-08-20T18:00:00Z"), ZoneOffset.UTC));
        return MockMvcBuilders.standaloneSetup(new SloController(queryService, evaluationService))
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
                .andExpect(jsonPath("$.burnRateEvaluation.allowedBadRatio").value(0.001))
                .andExpect(jsonPath("$.burnRateEvaluation.observedBadRatio").value(0.001))
                .andExpect(jsonPath("$.burnRateEvaluation.burnRate").value(1))
                .andExpect(jsonPath("$.burnRateEvaluation.status").value("AVAILABLE"))
                .andExpect(jsonPath("$.reason").doesNotExist());
    }

    @Test
    void returnsProblemDetailForUnknownDefinition() throws Exception {
        mvc.perform(get("/api/slos/missing"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.title").value("SLO not found"));
    }

    @Test
    void exposesZeroBudgetAsUnavailableBurnWithoutNonFiniteJson() throws Exception {
        MockMvc zeroBudgetMvc = mvc(
                definition(SliType.AVAILABILITY, "1"),
                ignored -> new RequestOutcomeMeasurement(1000d, 1d));

        zeroBudgetMvc.perform(get("/api/slos/checkout-availability/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("BREACHED"))
                .andExpect(jsonPath("$.burnRateEvaluation.allowedBadRatio").value(0))
                .andExpect(jsonPath("$.burnRateEvaluation.observedBadRatio").value(0.001))
                .andExpect(jsonPath("$.burnRateEvaluation.burnRate").value(nullValue()))
                .andExpect(jsonPath("$.burnRateEvaluation.status").value("UNAVAILABLE"))
                .andExpect(jsonPath("$.burnRateEvaluation.reason").value("ZERO_ALLOWED_BAD_RATIO"));
    }

    @Test
    void exposesNoTrafficWithoutFabricatingObservedOrBurnValues() throws Exception {
        MockMvc unavailableMvc = mvc(
                definition(SliType.AVAILABILITY, "0.999"),
                ignored -> new RequestOutcomeMeasurement(0d, 0d));

        unavailableMvc.perform(get("/api/slos/checkout-availability/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UNAVAILABLE"))
                .andExpect(jsonPath("$.reason").value("NO_TRAFFIC"))
                .andExpect(jsonPath("$.burnRateEvaluation.allowedBadRatio").value(0.001))
                .andExpect(jsonPath("$.burnRateEvaluation.observedBadRatio").value(nullValue()))
                .andExpect(jsonPath("$.burnRateEvaluation.burnRate").value(nullValue()))
                .andExpect(jsonPath("$.burnRateEvaluation.status").value("UNAVAILABLE"))
                .andExpect(jsonPath("$.burnRateEvaluation.reason").value("NO_TRAFFIC"));
    }

    @Test
    void serializesTheMaximumPossibleBurnForATinyAllowedRatioAsAFiniteJavaScriptNumber() throws Exception {
        MockMvc tinyBudgetMvc = mvc(
                definition(SliType.ERROR_RATE, "1E-308"),
                ignored -> new RequestOutcomeMeasurement(1d, 1d));

        String json = tinyBudgetMvc.perform(get("/api/slos/checkout-availability/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.burnRateEvaluation.allowedBadRatio").value(1E-308))
                .andExpect(jsonPath("$.burnRateEvaluation.status").value("AVAILABLE"))
                .andReturn().getResponse().getContentAsString();
        double parsedBurnRate = new ObjectMapper().readTree(json)
                .path("burnRateEvaluation").path("burnRate").doubleValue();

        assertThat(parsedBurnRate).isFinite().isEqualTo(1E+308);
    }

    private static SloDefinition definition(SliType type, String target) {
        return new SloDefinition(
                "checkout-availability", "Checkout availability", null,
                new ServiceIdentity("checkout", "commerce", "production"),
                type, new BigDecimal(target), EvaluationWindow.PT5M, true);
    }
}
