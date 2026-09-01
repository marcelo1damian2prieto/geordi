package io.geordi.alerts.adapter.out.config;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.AlertRoutingPort;
import io.geordi.alerts.application.port.out.NotificationDestinationRegistry;
import io.geordi.alerts.domain.AlertRoutingAction;
import io.geordi.alerts.domain.AlertRoutingPredicate;
import io.geordi.alerts.domain.AlertRoutingRule;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.RoutingDecision;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/**
 * Immutable deployment-configuration adapter for deterministic ordered alert routing.
 *
 * <p>Rules are evaluated in declaration order. Configuration changes affect only transitions routed
 * after this adapter is constructed; persisted delivery bindings are never used to route again.</p>
 */
public final class ConfigurationAlertRoutingAdapter
        implements AlertRoutingPort, NotificationDestinationRegistry {

    public static final int MAXIMUM_DESTINATIONS = 20;
    public static final int MAXIMUM_ROUTES = 100;

    private final Map<String, NotificationDestination> destinations;
    private final Map<String, WebhookDestinationConfiguration> webhookDestinations;
    private final List<AlertRoutingRule> routes;

    public ConfigurationAlertRoutingAdapter(AlertRoutingProperties properties, AlertPolicyCatalog policyCatalog) {
        Objects.requireNonNull(properties, "alert routing properties must not be null");
        Objects.requireNonNull(policyCatalog, "alert policy catalog must not be null");
        if (properties.destinations().size() > MAXIMUM_DESTINATIONS) {
            throw new IllegalArgumentException("alert routing must not exceed 20 destinations");
        }
        if (properties.routes().size() > MAXIMUM_ROUTES) {
            throw new IllegalArgumentException("alert routing must not exceed 100 routes");
        }
        webhookDestinations = webhookDestinations(properties);
        destinations = webhookDestinations.values().stream().collect(java.util.stream.Collectors.toUnmodifiableMap(
                configured -> configured.destination().id(), WebhookDestinationConfiguration::destination));
        routes = routes(properties, policyCatalog, destinations.keySet());
    }

    @Override
    public RoutingDecision route(AlertTransition transition) {
        Objects.requireNonNull(transition, "routing transition must not be null");
        for (AlertRoutingRule rule : routes) {
            if (rule.predicate().matches(transition)) {
                return rule.action() == AlertRoutingAction.DELIVER
                        ? RoutingDecision.matched(destinations.get(rule.destinationId()))
                        : RoutingDecision.suppressed();
            }
        }
        return RoutingDecision.unrouted();
    }

    @Override
    public Optional<NotificationDestination> findById(String destinationId) {
        return Optional.ofNullable(destinations.get(destinationId));
    }

    /**
     * Resolves endpoint settings only for the exact immutable destination binding persisted with a
     * delivery. A missing or changed destination deliberately returns empty so the worker cannot
     * fall back or reroute the delivery.
     */
    public Optional<WebhookDestinationConfiguration> resolveWebhookDestination(
            NotificationDestination persistedDestination) {
        Objects.requireNonNull(persistedDestination, "persisted notification destination must not be null");
        WebhookDestinationConfiguration configured = webhookDestinations.get(persistedDestination.id());
        return configured != null && configured.destination().equals(persistedDestination)
                ? Optional.of(configured) : Optional.empty();
    }

    private static Map<String, WebhookDestinationConfiguration> webhookDestinations(AlertRoutingProperties properties) {
        LinkedHashMap<String, WebhookDestinationConfiguration> mapped = new LinkedHashMap<>();
        for (AlertRoutingProperties.DestinationSettings settings : properties.destinations()) {
            if (settings == null) {
                throw new IllegalArgumentException("routing destination must not be null");
            }
            validateEndpointSecurity(settings.endpoint(), properties.allowInsecureLocalHttp());
            NotificationDestination destination = new NotificationDestination(settings.id(), fingerprint(settings));
            if (mapped.putIfAbsent(destination.id(), new WebhookDestinationConfiguration(
                    destination, settings.endpoint(), settings.token(), settings.tokenHeader())) != null) {
                throw new IllegalArgumentException("alert routing contains a duplicate destination id");
            }
        }
        return Map.copyOf(mapped);
    }

    private static List<AlertRoutingRule> routes(
            AlertRoutingProperties properties, AlertPolicyCatalog policyCatalog, Set<String> destinationIds) {
        Set<String> ids = new HashSet<>();
        Set<AlertRoutingPredicate> predicates = new HashSet<>();
        return properties.routes().stream().map(settings -> map(settings, policyCatalog, destinationIds, ids, predicates)).toList();
    }

    private static AlertRoutingRule map(
            AlertRoutingProperties.RouteSettings settings,
            AlertPolicyCatalog policyCatalog,
            Set<String> destinationIds,
            Set<String> ids,
            Set<AlertRoutingPredicate> predicates) {
        if (settings == null) {
            throw new IllegalArgumentException("routing route must not be null");
        }
        AlertRoutingPredicate predicate = new AlertRoutingPredicate(
                settings.policyId(), settings.serviceNamespace(), settings.serviceName(), settings.environment(),
                transitionType(settings.transitionType()));
        AlertRoutingRule rule = new AlertRoutingRule(settings.id(), predicate, action(settings.action()), settings.destinationId());
        if (!ids.add(rule.id())) {
            throw new IllegalArgumentException("alert routing contains a duplicate route id");
        }
        if (!predicates.add(predicate)) {
            throw new IllegalArgumentException("alert routing contains duplicate route predicates");
        }
        if (predicate.policyId() != null && policyCatalog.findById(predicate.policyId()).isEmpty()) {
            throw new IllegalArgumentException("routing route references an unknown alert policy");
        }
        if (rule.action() == AlertRoutingAction.DELIVER && !destinationIds.contains(rule.destinationId())) {
            throw new IllegalArgumentException("routing route references an unknown destination");
        }
        return rule;
    }

    private static AlertTransitionType transitionType(String value) {
        if (value == null) {
            return null;
        }
        try {
            return AlertTransitionType.valueOf(value);
        } catch (IllegalArgumentException exception) {
            throw new IllegalArgumentException("unsupported routing transition type", exception);
        }
    }

    private static AlertRoutingAction action(String value) {
        try {
            return AlertRoutingAction.valueOf(value);
        } catch (NullPointerException | IllegalArgumentException exception) {
            throw new IllegalArgumentException("unsupported routing action", exception);
        }
    }

    private static void validateEndpointSecurity(URI endpoint, boolean allowInsecureLocalHttp) {
        boolean secure = "https".equalsIgnoreCase(endpoint.getScheme());
        boolean localTest = allowInsecureLocalHttp && "http".equalsIgnoreCase(endpoint.getScheme())
                && ("localhost".equalsIgnoreCase(endpoint.getHost())
                || "webhook-receiver".equalsIgnoreCase(endpoint.getHost())
                || "webhook-receiver-a".equalsIgnoreCase(endpoint.getHost())
                || "webhook-receiver-b".equalsIgnoreCase(endpoint.getHost()));
        if (!secure && !localTest) {
            throw new IllegalArgumentException("routing destination endpoint must use HTTPS");
        }
    }

    private static String fingerprint(AlertRoutingProperties.DestinationSettings settings) {
        String value = settings.id() + "\n" + settings.endpoint().normalize() + "\n"
                + (settings.tokenHeader() == null ? "" : settings.tokenHeader().toLowerCase(Locale.ROOT));
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 must be available", exception);
        }
    }

    /**
     * HTTP adapter settings deliberately kept out of the domain and with a redacted string form.
     */
    public static final class WebhookDestinationConfiguration {
        private final NotificationDestination destination;
        private final URI endpoint;
        private final String token;
        private final String tokenHeader;

        private WebhookDestinationConfiguration(
                NotificationDestination destination, URI endpoint, String token, String tokenHeader) {
            this.destination = destination;
            this.endpoint = endpoint;
            this.token = token;
            this.tokenHeader = tokenHeader;
        }

        public NotificationDestination destination() {
            return destination;
        }

        public URI endpoint() {
            return endpoint;
        }

        public String token() {
            return token;
        }

        public String tokenHeader() {
            return tokenHeader;
        }

        @Override
        public String toString() {
            return "WebhookDestinationConfiguration[destinationId=" + destination.id() + "]";
        }
    }
}
