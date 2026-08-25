package io.geordi.alerts.adapter.in.web;

import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyNotFoundException;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class AlertPolicyControllerTest {

    private static final Instant NOW = Instant.parse("2026-08-25T18:00:00Z");
    private static final AlertPolicy POLICY = new AlertPolicy(
            "checkout-burn", "Checkout burn", "Current burn", true, "checkout-availability",
            new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")));

    @Test
    void exposesTheReadOnlyCatalogShape() throws Exception {
        mvc(ignored -> evaluation()).perform(get("/api/alert-policies"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertPolicies[0].id").value("checkout-burn"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.type").value("BURN_RATE_ABOVE"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.threshold").value(2));
    }

    @Test
    void exposesExactlyTheNestedCanonicalEvidenceContract() throws Exception {
        mvc(ignored -> evaluation()).perform(get("/api/alert-policies/checkout-burn/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.policyId").value("checkout-burn"))
                .andExpect(jsonPath("$.status").value("CONDITION_MET"))
                .andExpect(jsonPath("$.reason").value(nullValue()))
                .andExpect(jsonPath("$.evidence.service.name").value("checkout"))
                .andExpect(jsonPath("$.evidence.service.namespace").value("commerce"))
                .andExpect(jsonPath("$.evidence.service.environment").value("production"))
                .andExpect(jsonPath("$.evidence.window").value("PT5M"))
                .andExpect(jsonPath("$.evidence.range.from").value("2026-08-25T17:55:00Z"))
                .andExpect(jsonPath("$.evidence.range.to").value("2026-08-25T18:00:00Z"))
                .andExpect(jsonPath("$.evidence.evaluatedAt").value("2026-08-25T18:00:00Z"))
                .andExpect(jsonPath("$.evidence.observedBurnRate").value(3.7));
    }

    @Test
    void exposesDisabledAsUnavailableWithoutEvidenceAndUnknownAsNotFound() throws Exception {
        AlertEvaluation disabled = new AlertEvaluation(
                POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(),
                AlertEvaluationStatus.UNAVAILABLE, AlertUnavailableReason.DISABLED, null);
        mvc(id -> "missing".equals(id) ? throwNotFound() : disabled)
                .perform(get("/api/alert-policies/checkout-burn/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UNAVAILABLE"))
                .andExpect(jsonPath("$.reason").value("DISABLED"))
                .andExpect(jsonPath("$.evidence").value(nullValue()));

        mvc(id -> throwNotFound()).perform(get("/api/alert-policies/missing/evaluation"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.title").value("Alert policy not found"));
    }

    @Test
    void exposesNoTrafficProviderFailureAndZeroBudgetAsUnavailableWithContext() throws Exception {
        for (AlertUnavailableReason reason : List.of(
                AlertUnavailableReason.NO_TRAFFIC,
                AlertUnavailableReason.METRICS_UNAVAILABLE,
                AlertUnavailableReason.ZERO_ALLOWED_BAD_RATIO)) {
            BurnRateEvidence evidence = new BurnRateEvidence(
                    "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                    EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW, null, reason);
            AlertEvaluation unavailable = new AlertEvaluation(
                    POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(),
                    AlertEvaluationStatus.UNAVAILABLE, reason, evidence);

            mvc(ignored -> unavailable).perform(get("/api/alert-policies/checkout-burn/evaluation"))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.status").value("UNAVAILABLE"))
                    .andExpect(jsonPath("$.reason").value(reason.name()))
                    .andExpect(jsonPath("$.evidence.observedBurnRate").value(nullValue()))
                    .andExpect(jsonPath("$.evidence.range.to").value("2026-08-25T18:00:00Z"));
        }
    }

    private static AlertEvaluation throwNotFound() {
        throw new AlertPolicyNotFoundException();
    }

    private static MockMvc mvc(AlertEvaluationUseCase evaluations) {
        AlertPolicyCatalog catalog = new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(POLICY);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return Optional.of(POLICY);
            }
        };
        AlertPolicyController controller = new AlertPolicyController(
                new AlertPolicyQueryService(catalog), evaluations);
        return MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new AlertPolicyExceptionHandler()).build();
    }

    private static AlertEvaluation evaluation() {
        BurnRateEvidence evidence = new BurnRateEvidence(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW,
                new BigDecimal("3.7"), null);
        return new AlertEvaluation(
                POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(),
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
    }
}
