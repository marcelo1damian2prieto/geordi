package io.geordi.alerts.adapter.in.web;

import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.alerts.application.AlertLifecycleEvaluationResult;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.AlertLifecycleQueryService;
import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleBindingMismatchException;
import io.geordi.alerts.domain.AlertLifecycleProcessingOutcome;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.BurnRateBand;
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

class AlertLifecycleControllerTest {

    private static final Instant NOW = Instant.parse("2026-08-27T17:00:00Z");
    private static final AlertPolicy POLICY = new AlertPolicy(
            "checkout-burn", "Checkout burn", "Current burn", true, "checkout-availability",
            new BurnRateAboveCondition(new BigDecimal("2")));

    @Test
    void listsConfiguredPoliciesAsExplicitlyUninitializedAndInactive() throws Exception {
        mvc(id -> result(), repository()).perform(get("/api/alert-states"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.alertStates[0].policy.id").value("checkout-burn"))
                .andExpect(jsonPath("$.alertStates[0].initialized").value(false))
                .andExpect(jsonPath("$.alertStates[0].state").value("INACTIVE"))
                .andExpect(jsonPath("$.alertStates[0].latestEvaluation").value(nullValue()))
                .andExpect(jsonPath("$.alertStates[0].lastProcessedAt").value(nullValue()));
    }

    @Test
    void exposesAppliedLifecycleAndCanonicalStartedTransition() throws Exception {
        mvc(id -> result(), repository())
                .perform(post("/api/alert-policies/checkout-burn/lifecycle-evaluations"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.triggeringEvaluation.status").value("CONDITION_MET"))
                .andExpect(jsonPath("$.outcome").value("APPLIED"))
                .andExpect(jsonPath("$.current.initialized").value(true))
                .andExpect(jsonPath("$.current.state").value("FIRING"))
                .andExpect(jsonPath("$.current.startedAt").value("2026-08-27T17:00:00Z"))
                .andExpect(jsonPath("$.current.activeEvidence.service.namespace").value("commerce"))
                .andExpect(jsonPath("$.current.activeEvidence.range.from").value("2026-08-27T16:55:00Z"))
                .andExpect(jsonPath("$.transition.type").value("ALERT_STARTED"))
                .andExpect(jsonPath("$.transition.previousState").value("INACTIVE"))
                .andExpect(jsonPath("$.transition.currentState").value("FIRING"))
                .andExpect(jsonPath("$.transition.occurredAt").value("2026-08-27T17:00:00Z"));
    }

    @Test
    void retainsCompleteMultiwindowActiveEvidenceAcrossLifecycleMappings() throws Exception {
        AlertPolicy policy = multiwindowPolicy();
        AlertEvaluation evaluation = multiwindowEvaluation(policy);
        var decision = AlertLifecycleTransitions.apply(Optional.empty(), evaluation, null);
        AlertLifecycleEvaluationResult result = new AlertLifecycleEvaluationResult(
                policy, evaluation, AlertLifecycleProcessingOutcome.APPLIED,
                decision.current(), decision.transition());
        AlertLifecycleController controller = new AlertLifecycleController(
                new AlertLifecycleQueryService(catalog(policy), repository(), bindings(policy)), ignored -> result);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new AlertPolicyExceptionHandler()).build();

        mvc.perform(post("/api/alert-policies/multiwindow-burn/lifecycle-evaluations"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.triggeringEvaluation.condition.type").value("MULTIWINDOW_BURN_RATE"))
                .andExpect(jsonPath("$.triggeringEvaluation.bandResults[0].outcome").value("MET"))
                .andExpect(jsonPath("$.current.activeEvidence.configuredSloWindow").value("PT5M"))
                .andExpect(jsonPath("$.current.activeEvidence.observations.length()").value(2))
                .andExpect(jsonPath("$.current.activeEvidence.observations[0].observationWindow").value("PT5M"))
                .andExpect(jsonPath("$.current.activeEvidence.observations[1].observationWindow").value("PT1H"))
                .andExpect(jsonPath("$.transition.evaluation.bandResults[0].outcome").value("MET"));
    }

    @Test
    void mapsImmutableBindingConflictWithoutLeakingStorageDetails() throws Exception {
        mvc(id -> {
            throw new AlertLifecycleBindingMismatchException();
        }, repository()).perform(post("/api/alert-policies/checkout-burn/lifecycle-evaluations"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.title").value("Alert lifecycle identity conflict"))
                .andExpect(jsonPath("$.detail")
                        .value("Persisted lifecycle identity conflicts with the canonical alert evaluation"));
    }

    @Test
    void failsClosedWhenAStoredLifecycleNoLongerMatchesTheConfiguredPolicy() throws Exception {
        AlertLifecycle persisted = result().current();
        AlertPolicy changed = new AlertPolicy(
                POLICY.id(), POLICY.name(), POLICY.description(), POLICY.enabled(), POLICY.sloId(),
                new BurnRateAboveCondition(new BigDecimal("4")));
        AlertPolicyCatalog changedCatalog = new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(changed);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return changed.id().equals(id) ? Optional.of(changed) : Optional.empty();
            }
        };
        AlertLifecycleRepository stored = repositoryWith(persisted);
        AlertLifecycleController controller = new AlertLifecycleController(
                new AlertLifecycleQueryService(changedCatalog, stored, bindings()), id -> result());
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new AlertPolicyExceptionHandler()).build();

        mvc.perform(get("/api/alert-states"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.title").value("Alert lifecycle identity conflict"));
    }

    @Test
    void failsClosedWhenTheCurrentSloServiceOrWindowNoLongerMatchesStoredState() throws Exception {
        AlertLifecycleRepository stored = repositoryWith(result().current());
        SloLifecycleBindingPort changedBinding = ignored -> Optional.of(new SloLifecycleBindingPort.Binding(
                POLICY.sloId(), new ServiceIdentity("payments", "commerce", "production"),
                EvaluationWindow.PT15M));
        AlertLifecycleController controller = new AlertLifecycleController(
                new AlertLifecycleQueryService(catalog(), stored, changedBinding), id -> result());
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new AlertPolicyExceptionHandler()).build();

        mvc.perform(get("/api/alert-states"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.title").value("Alert lifecycle identity conflict"));
    }

    private static MockMvc mvc(
            AlertLifecycleEvaluationUseCase evaluations, AlertLifecycleRepository repository) {
        AlertLifecycleController controller = new AlertLifecycleController(
                new AlertLifecycleQueryService(catalog(), repository, bindings()), evaluations);
        return MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new AlertPolicyExceptionHandler()).build();
    }

    private static AlertLifecycleEvaluationResult result() {
        AlertEvaluation evaluation = evaluation();
        var decision = AlertLifecycleTransitions.apply(Optional.empty(), evaluation, null);
        return new AlertLifecycleEvaluationResult(
                POLICY, evaluation, AlertLifecycleProcessingOutcome.APPLIED,
                decision.current(), decision.transition());
    }

    private static AlertEvaluation evaluation() {
        BurnRateEvidence evidence = new BurnRateEvidence(
                POLICY.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(NOW.minusSeconds(300), NOW), NOW,
                new BigDecimal("3.7"), null);
        return new AlertEvaluation(
                POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(),
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
    }

    private static AlertPolicyCatalog catalog() {
        return catalog(POLICY);
    }

    private static AlertPolicyCatalog catalog(AlertPolicy policy) {
        return new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(policy);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return policy.id().equals(id) ? Optional.of(policy) : Optional.empty();
            }
        };
    }

    private static SloLifecycleBindingPort bindings() {
        return bindings(POLICY);
    }

    private static SloLifecycleBindingPort bindings(AlertPolicy policy) {
        return ignored -> Optional.of(new SloLifecycleBindingPort.Binding(
                policy.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M));
    }

    private static AlertPolicy multiwindowPolicy() {
        return new AlertPolicy(
                "multiwindow-burn", "Multiwindow burn", null, true, "checkout-availability",
                new MultiwindowBurnRateCondition(List.of(new BurnRateBand(
                        AlertObservationWindow.PT1H, AlertObservationWindow.PT5M, new BigDecimal("2")))));
    }

    private static AlertEvaluation multiwindowEvaluation(AlertPolicy policy) {
        MultiwindowBurnRateCondition condition = (MultiwindowBurnRateCondition) policy.condition();
        MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                policy.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, NOW, Set.copyOf(condition.observationWindows()), List.of(
                        new WindowBurnRateObservation(
                                AlertObservationWindow.PT1H,
                                new TimeRange(NOW.minus(AlertObservationWindow.PT1H.duration()), NOW),
                                new BigDecimal("3"), null),
                        new WindowBurnRateObservation(
                                AlertObservationWindow.PT5M,
                                new TimeRange(NOW.minus(AlertObservationWindow.PT5M.duration()), NOW),
                                new BigDecimal("2"), null)));
        return new AlertEvaluation(
                policy.id(), policy.name(), policy.sloId(), condition,
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
    }

    private static AlertLifecycleRepository repository() {
        return new AlertLifecycleRepository() {
            @Override
            public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
                return Optional.empty();
            }

            @Override
            public List<VersionedAlertLifecycle> findAll() {
                return List.of();
            }

            @Override
            public boolean insertIfAbsent(AlertLifecycle lifecycle) {
                return true;
            }

            @Override
            public boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion) {
                return true;
            }
        };
    }

    private static AlertLifecycleRepository repositoryWith(AlertLifecycle lifecycle) {
        return new AlertLifecycleRepository() {
            @Override
            public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
                return lifecycle.policyId().equals(policyId)
                        ? Optional.of(new VersionedAlertLifecycle(lifecycle, 0))
                        : Optional.empty();
            }

            @Override
            public List<VersionedAlertLifecycle> findAll() {
                return List.of(new VersionedAlertLifecycle(lifecycle, 0));
            }

            @Override
            public boolean insertIfAbsent(AlertLifecycle value) {
                return false;
            }

            @Override
            public boolean replaceIfVersionMatches(AlertLifecycle value, long expectedVersion) {
                return false;
            }
        };
    }
}
