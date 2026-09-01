package io.geordi.alerts.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.RoutingDecision;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.net.URI;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class ConfigurationAlertRoutingAdapterTest {

    @Test
    void routesExactPolicyAndServiceDimensionsToConfiguredDestination() {
        var adapter = adapter(routes(route(
                "checkout", "checkout-burn", "commerce", "checkout", "production", "ALERT_STARTED", "DELIVER", "a")));

        RoutingDecision decision = adapter.route(started("checkout-burn", "commerce", "checkout", "production"));

        assertThat(decision).isInstanceOf(RoutingDecision.Matched.class);
        assertThat(((RoutingDecision.Matched) decision).destination().id()).isEqualTo("a");
        assertThat(adapter.findById("a")).isPresent();
    }

    @Test
    void evaluatesStartedAndResolvedRulesIndependently() {
        var adapter = adapter(routes(
                route("started", null, null, null, null, "ALERT_STARTED", "DELIVER", "a"),
                route("resolved", null, null, null, null, "ALERT_RESOLVED", "DELIVER", "b")));

        assertThat(destinationId(adapter.route(started("checkout-burn", "commerce", "checkout", "production"))))
                .isEqualTo("a");
        assertThat(destinationId(adapter.route(resolved("checkout-burn", "commerce", "checkout", "production"))))
                .isEqualTo("b");
    }

    @Test
    void honorsDeclaredFirstMatchBeforeMoreGeneralRules() {
        var adapter = adapter(routes(
                route("specific", "checkout-burn", null, null, null, null, "DELIVER", "b"),
                route("catch-all", null, null, null, null, null, "DELIVER", "a")));

        assertThat(destinationId(adapter.route(started("checkout-burn", "commerce", "checkout", "production"))))
                .isEqualTo("b");
    }

    @Test
    void returnsExplicitSuppressedAndUnroutedTerminalDecisions() {
        var suppressed = adapter(routes(route(
                "suppress", "checkout-burn", null, null, null, null, "SUPPRESS", null)));
        var unrouted = adapter(routes());
        AlertTransition transition = started("checkout-burn", "commerce", "checkout", "production");

        assertThat(suppressed.route(transition)).isSameAs(RoutingDecision.suppressed());
        assertThat(unrouted.route(transition)).isSameAs(RoutingDecision.unrouted());
    }

    @Test
    void rejectsDuplicatePredicatesAndUnsafeOrUnknownConfiguration() {
        assertThatThrownBy(() -> adapter(routes(
                route("one", null, null, null, null, null, "DELIVER", "a"),
                route("two", null, null, null, null, null, "DELIVER", "b"))))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert routing contains duplicate route predicates");
        assertThatThrownBy(() -> adapter(routes(route(
                "unknown-policy", "missing", null, null, null, null, "DELIVER", "a"))))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing route references an unknown alert policy");
        assertThatThrownBy(() -> adapter(routes(route(
                "unknown-destination", null, null, null, null, null, "DELIVER", "missing"))))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing route references an unknown destination");
        assertThatThrownBy(() -> new AlertRoutingProperties.DestinationSettings(
                "a", URI.create("https://hooks.example.test/a"), "secret", null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing destination token and token header must be supplied together");
        assertThatThrownBy(() -> new AlertRoutingProperties.DestinationSettings(
                "a", URI.create("https://hooks.example.test/a?token=secret"), null, null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing destination endpoint is invalid");
        assertThatThrownBy(() -> adapter(new AlertRoutingProperties(
                List.of(destination("a", "http://external.example.test/a")), List.of(), false)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing destination endpoint must use HTTPS");
    }

    @Test
    void normalizesBlankWebhookCredentialsAndRejectsPartiallyBlankCredentialPairs() {
        AlertRoutingProperties.DestinationSettings unauthenticated = new AlertRoutingProperties.DestinationSettings(
                "a", URI.create("https://hooks.example.test/a"), "  ", "\t");

        assertThat(unauthenticated.token()).isNull();
        assertThat(unauthenticated.tokenHeader()).isNull();
        assertThatThrownBy(() -> new AlertRoutingProperties.DestinationSettings(
                "a", URI.create("https://hooks.example.test/a"), "  ", "X-Geordi-Token"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing destination token and token header must be supplied together");
        assertThatThrownBy(() -> new AlertRoutingProperties.DestinationSettings(
                "a", URI.create("https://hooks.example.test/a"), "secret", "  "))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("routing destination token and token header must be supplied together");
    }

    @Test
    void usesASecretFreeStableDestinationFingerprint() {
        var first = adapter(new AlertRoutingProperties(
                List.of(new AlertRoutingProperties.DestinationSettings(
                        "a", URI.create("https://hooks.example.test/a"), "first-secret", "X-Geordi-Token")),
                List.of(), false));
        var second = adapter(new AlertRoutingProperties(
                List.of(new AlertRoutingProperties.DestinationSettings(
                        "a", URI.create("https://hooks.example.test/a"), "rotated-secret", "X-Geordi-Token")),
                List.of(), false));

        assertThat(first.findById("a").orElseThrow().configurationFingerprint())
                .isEqualTo(second.findById("a").orElseThrow().configurationFingerprint())
                .doesNotContain("secret");
    }

    @Test
    void resolvesWebhookSettingsOnlyForTheExactPersistedDestinationBinding() {
        var adapter = adapter(routes(route(
                "deliver", null, null, null, null, null, "DELIVER", "a")));
        RoutingDecision.Matched matched = (RoutingDecision.Matched) adapter.route(
                started("checkout-burn", "commerce", "checkout", "production"));

        assertThat(adapter.resolveWebhookDestination(matched.destination())).isPresent().get()
                .extracting(ConfigurationAlertRoutingAdapter.WebhookDestinationConfiguration::endpoint)
                .isEqualTo(URI.create("https://hooks.example.test/a"));
        assertThat(adapter.resolveWebhookDestination(new io.geordi.alerts.domain.NotificationDestination(
                "a", "different-fingerprint"))).isEmpty();
        assertThat(adapter.resolveWebhookDestination(matched.destination()).orElseThrow().toString())
                .doesNotContain("hooks.example.test", "secret");
    }

    private static String destinationId(RoutingDecision decision) {
        return ((RoutingDecision.Matched) decision).destination().id();
    }

    private static ConfigurationAlertRoutingAdapter adapter(AlertRoutingProperties properties) {
        return new ConfigurationAlertRoutingAdapter(properties, catalog());
    }

    private static AlertRoutingProperties routes(AlertRoutingProperties.RouteSettings... settings) {
        return new AlertRoutingProperties(
                List.of(destination("a", "https://hooks.example.test/a"), destination("b", "https://hooks.example.test/b")),
                List.of(settings), false);
    }

    private static AlertRoutingProperties.DestinationSettings destination(String id, String endpoint) {
        return new AlertRoutingProperties.DestinationSettings(id, URI.create(endpoint), "secret", "X-Geordi-Token");
    }

    private static AlertRoutingProperties.RouteSettings route(
            String id, String policyId, String namespace, String service, String environment,
            String transitionType, String action, String destinationId) {
        return new AlertRoutingProperties.RouteSettings(
                id, policyId, namespace, service, environment, transitionType, action, destinationId);
    }

    private static AlertPolicyCatalog catalog() {
        AlertPolicy policy = new AlertPolicy("checkout-burn", "Checkout", null, true, "slo",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE));
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

    private static AlertTransition started(String policyId, String namespace, String service, String environment) {
        return transition(policyId, namespace, service, environment, AlertEvaluationStatus.CONDITION_MET,
                AlertTransitionType.ALERT_STARTED, AlertLifecycleState.INACTIVE, AlertLifecycleState.FIRING);
    }

    private static AlertTransition resolved(String policyId, String namespace, String service, String environment) {
        return transition(policyId, namespace, service, environment, AlertEvaluationStatus.CONDITION_NOT_MET,
                AlertTransitionType.ALERT_RESOLVED, AlertLifecycleState.FIRING, AlertLifecycleState.INACTIVE);
    }

    private static AlertTransition transition(
            String policyId, String namespace, String service, String environment, AlertEvaluationStatus status,
            AlertTransitionType type, AlertLifecycleState previous, AlertLifecycleState current) {
        Instant now = Instant.parse("2026-09-01T12:00:00Z");
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE);
        BigDecimal observedBurnRate = status == AlertEvaluationStatus.CONDITION_MET ? BigDecimal.TEN : BigDecimal.ZERO;
        AlertEvaluation evaluation = new AlertEvaluation(policyId, "Policy", "slo", condition, status, null,
                new BurnRateEvidence("slo", new ServiceIdentity(service, namespace, environment), EvaluationWindow.PT5M,
                        new TimeRange(now.minusSeconds(300), now), now, observedBurnRate, null));
        return new AlertTransition(policyId, type, previous, current, now, evaluation);
    }
}
