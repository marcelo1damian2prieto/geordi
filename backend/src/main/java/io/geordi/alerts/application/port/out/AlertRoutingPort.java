package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.RoutingDecision;

/** Selects one terminal routing outcome for a canonical lifecycle transition. */
@FunctionalInterface
public interface AlertRoutingPort {

    RoutingDecision route(AlertTransition transition);
}
