package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.NotificationDestination;
import java.util.Optional;

/** Resolves a current non-secret notification destination identity by its stable identifier. */
public interface NotificationDestinationRegistry {

    Optional<NotificationDestination> findById(String destinationId);
}
