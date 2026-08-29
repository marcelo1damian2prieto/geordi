package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.NotificationDestination;
import java.util.Optional;

/**
 * Resolves whether a canonical transition is eligible for durable notification delivery.
 */
@FunctionalInterface
public interface NotificationDestinationSelector {

    Optional<NotificationDestination> selectFor(AlertTransition transition);
}
