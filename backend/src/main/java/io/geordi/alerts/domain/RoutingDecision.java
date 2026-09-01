package io.geordi.alerts.domain;

import java.util.Objects;

/**
 * The terminal result of routing one canonical lifecycle transition.
 *
 * <p>Suppressed and unrouted transitions deliberately carry no destination and therefore create no
 * delivery work. A matched destination is an immutable non-secret binding for one delivery.</p>
 */
public sealed interface RoutingDecision permits RoutingDecision.Matched, RoutingDecision.Suppressed, RoutingDecision.Unrouted {

    static Matched matched(NotificationDestination destination) {
        return new Matched(destination);
    }

    static Suppressed suppressed() {
        return Suppressed.INSTANCE;
    }

    static Unrouted unrouted() {
        return Unrouted.INSTANCE;
    }

    record Matched(NotificationDestination destination) implements RoutingDecision {
        public Matched {
            Objects.requireNonNull(destination, "matched routing destination must not be null");
        }
    }

    enum Suppressed implements RoutingDecision {
        INSTANCE
    }

    enum Unrouted implements RoutingDecision {
        INSTANCE
    }
}
