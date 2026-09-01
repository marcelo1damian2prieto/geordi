package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.port.out.AlertRoutingPort;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.RoutingDecision;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import java.util.Objects;

/** Emits bounded platform telemetry around one deterministic routing evaluation. */
public final class ObservedAlertRoutingPort implements AlertRoutingPort {

    private static final AttributeKey<String> TRANSITION_TYPE =
            AttributeKey.stringKey("geordi.alert.routing.transition.type");

    private final AlertRoutingPort delegate;
    private final LongCounter evaluations;
    private final LongCounter matched;
    private final LongCounter suppressed;
    private final LongCounter unrouted;
    private final LongCounter failures;

    public ObservedAlertRoutingPort(AlertRoutingPort delegate) {
        this(delegate, GlobalOpenTelemetry.getMeter("io.geordi.alerts"));
    }

    ObservedAlertRoutingPort(AlertRoutingPort delegate, Meter meter) {
        this.delegate = Objects.requireNonNull(delegate, "alert routing delegate must not be null");
        Objects.requireNonNull(meter, "alert routing meter must not be null");
        evaluations = meter.counterBuilder("geordi.alert.routing.evaluations").build();
        matched = meter.counterBuilder("geordi.alert.routing.matched").build();
        suppressed = meter.counterBuilder("geordi.alert.routing.suppressed").build();
        unrouted = meter.counterBuilder("geordi.alert.routing.unrouted").build();
        failures = meter.counterBuilder("geordi.alert.routing.failures").build();
    }

    @Override
    public RoutingDecision route(AlertTransition transition) {
        Objects.requireNonNull(transition, "routing transition must not be null");
        Attributes attributes = Attributes.of(TRANSITION_TYPE, transitionType(transition.type()));
        evaluations.add(1, attributes);
        try {
            RoutingDecision decision = Objects.requireNonNull(
                    delegate.route(transition), "alert routing decision must not be null");
            record(decision, attributes);
            return decision;
        } catch (RuntimeException exception) {
            failures.add(1, attributes);
            throw exception;
        }
    }

    private void record(RoutingDecision decision, Attributes attributes) {
        if (decision instanceof RoutingDecision.Matched) {
            matched.add(1, attributes);
        } else if (decision instanceof RoutingDecision.Suppressed) {
            suppressed.add(1, attributes);
        } else if (decision instanceof RoutingDecision.Unrouted) {
            unrouted.add(1, attributes);
        } else {
            throw new IllegalStateException("unsupported routing decision");
        }
    }

    private static String transitionType(AlertTransitionType type) {
        return switch (type) {
            case ALERT_STARTED -> "alert_started";
            case ALERT_RESOLVED -> "alert_resolved";
        };
    }
}
