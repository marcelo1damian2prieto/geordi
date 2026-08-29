package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.NotificationDelivery;

@FunctionalInterface
public interface NotificationDeliverySender {
    Result send(NotificationDelivery delivery);

    enum Result { DELIVERED, RETRYABLE_FAILURE, TERMINAL_FAILURE }
}
