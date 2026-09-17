package io.geordi.alerts.adapter.in.web;

import static org.hamcrest.Matchers.nullValue;
import static org.hamcrest.Matchers.hasSize;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.application.AlertPolicyNotFoundException;
import io.geordi.alerts.application.AlertPolicyQueryService;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class AlertPolicyControllerTest {

    private static final Instant NOW = Instant.parse("2026-08-25T18:00:00Z");
    private static final AlertPolicy POLICY = new AlertPolicy(
            "checkout-burn", "Checkout burn", "Current burn", true, "checkout-availability",
            new BurnRateAboveCondition(new BigDecimal("2")));

    @Test
    void exposesTheReadOnlyCatalogShape() throws Exception {
        mvc(ignored -> evaluation()).perform(get("/api/alert-policies"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertPolicies[0].id").value("checkout-burn"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.type").value("BURN_RATE_ABOVE"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.threshold").value(2))
                .andExpect(jsonPath("$.alertPolicies[0].condition.*", hasSize(2)))
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands").doesNotExist());
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
                .andExpect(jsonPath("$.evidence.observedBurnRate").value(3.7))
                .andExpect(jsonPath("$.*", hasSize(7)))
                .andExpect(jsonPath("$.condition.*", hasSize(2)))
                .andExpect(jsonPath("$.evidence.*", hasSize(5)))
                .andExpect(jsonPath("$.bandResults").doesNotExist());
    }

    @Test
    void exposesClosedCanonicalMultiwindowPolicyAndEvaluationVariants() throws Exception {
        AlertPolicy policy = multiwindowPolicy();
        AlertEvaluation evaluation = multiwindowEvaluation(policy);

        mvc(policy, ignored -> evaluation).perform(get("/api/alert-policies"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertPolicies[0].condition.type").value("MULTIWINDOW_BURN_RATE"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.threshold").doesNotExist())
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands.length()").value(2))
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands[0].longWindow").value("PT1H"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands[0].shortWindow").value("PT5M"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands[1].longWindow").value("PT6H"))
                .andExpect(jsonPath("$.alertPolicies[0].condition.bands[1].shortWindow").value("PT30M"));

        mvc(policy, ignored -> evaluation)
                .perform(get("/api/alert-policies/multiwindow-burn/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CONDITION_MET"))
                .andExpect(jsonPath("$.reason").value(nullValue()))
                .andExpect(jsonPath("$.evidence.configuredSloWindow").value("PT5M"))
                .andExpect(jsonPath("$.evidence.window").doesNotExist())
                .andExpect(jsonPath("$.evidence.observations.length()").value(4))
                .andExpect(jsonPath("$.evidence.observations[0].observationWindow").value("PT5M"))
                .andExpect(jsonPath("$.evidence.observations[1].observationWindow").value("PT30M"))
                .andExpect(jsonPath("$.evidence.observations[2].observationWindow").value("PT1H"))
                .andExpect(jsonPath("$.evidence.observations[3].observationWindow").value("PT6H"))
                .andExpect(jsonPath("$.bandResults[0].outcome").value("NOT_MET"))
                .andExpect(jsonPath("$.bandResults[1].outcome").value("MET"))
                .andExpect(jsonPath("$.bandResults[1].longObservation.observationWindow").value("PT6H"))
                .andExpect(jsonPath("$.bandResults[1].shortObservation.observationWindow").value("PT30M"))
                .andExpect(jsonPath("$.evidence.providerQuery").doesNotExist())
                .andExpect(jsonPath("$.evidence.requestCount").doesNotExist())
                .andExpect(jsonPath("$.persistenceFormatVersion").doesNotExist());
    }

    @Test
    void exposesBoundedLeafAndAggregateUnavailableReasonsForMultiwindowEvidence() throws Exception {
        AlertPolicy policy = new AlertPolicy(
                "multiwindow-burn", "Multiwindow burn", null, true, "checkout-availability",
                new MultiwindowBurnRateCondition(List.of(new BurnRateBand(
                        AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("2")))));
        MultiwindowBurnRateCondition condition = (MultiwindowBurnRateCondition) policy.condition();
        MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                policy.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, NOW, Set.copyOf(condition.observationWindows()), List.of(
                        unavailableObservation(AlertObservationWindow.PT1H),
                        unavailableObservation(AlertObservationWindow.PT5M)));
        AlertEvaluation unavailable = new AlertEvaluation(
                policy.id(), policy.name(), policy.sloId(), condition, AlertEvaluationStatus.UNAVAILABLE,
                AlertUnavailableReason.MULTIWINDOW_EVIDENCE_UNAVAILABLE, evidence);

        mvc(policy, ignored -> unavailable)
                .perform(get("/api/alert-policies/multiwindow-burn/evaluation"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.reason").value("MULTIWINDOW_EVIDENCE_UNAVAILABLE"))
                .andExpect(jsonPath("$.evidence.observations[0].observedBurnRate").value(nullValue()))
                .andExpect(jsonPath("$.evidence.observations[0].reason").value("METRICS_UNAVAILABLE"))
                .andExpect(jsonPath("$.bandResults[0].outcome").value("UNAVAILABLE"));
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
        return mvc(POLICY, evaluations);
    }

    private static MockMvc mvc(AlertPolicy policy, AlertEvaluationUseCase evaluations) {
        AlertPolicyCatalog catalog = new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(policy);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return Optional.of(policy);
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

    private static AlertPolicy multiwindowPolicy() {
        return new AlertPolicy(
                "multiwindow-burn", "Multiwindow burn", "Bounded burn", true, "checkout-availability",
                new MultiwindowBurnRateCondition(List.of(
                        new BurnRateBand(AlertObservationWindow.PT6H, AlertObservationWindow.PT30M,
                                new BigDecimal("6.00")),
                        new BurnRateBand(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M,
                                new BigDecimal("14.4")))));
    }

    private static AlertEvaluation multiwindowEvaluation(AlertPolicy policy) {
        ServiceIdentity service = new ServiceIdentity("checkout", "commerce", "production");
        List<WindowBurnRateObservation> observations = List.of(
                observation(AlertObservationWindow.PT6H, "6"),
                observation(AlertObservationWindow.PT1H, "15"),
                observation(AlertObservationWindow.PT30M, "6"),
                observation(AlertObservationWindow.PT5M, "1"));
        MultiwindowBurnRateCondition condition = (MultiwindowBurnRateCondition) policy.condition();
        MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                policy.sloId(), service, EvaluationWindow.PT5M, NOW,
                Set.copyOf(condition.observationWindows()), observations);
        return new AlertEvaluation(
                policy.id(), policy.name(), policy.sloId(), condition,
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
    }

    private static WindowBurnRateObservation observation(AlertObservationWindow window, String burnRate) {
        return new WindowBurnRateObservation(
                window, new TimeRange(NOW.minus(window.duration()), NOW), new BigDecimal(burnRate), null);
    }

    private static WindowBurnRateObservation unavailableObservation(AlertObservationWindow window) {
        return new WindowBurnRateObservation(
                window, new TimeRange(NOW.minus(window.duration()), NOW), null,
                AlertUnavailableReason.METRICS_UNAVAILABLE);
    }
}
