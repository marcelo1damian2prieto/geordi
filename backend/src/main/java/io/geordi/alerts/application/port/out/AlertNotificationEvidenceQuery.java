package io.geordi.alerts.application.port.out;

import io.geordi.alerts.application.AlertNotificationEvidence;
import io.geordi.alerts.domain.AlertTransitionId;
import java.util.List;

public interface AlertNotificationEvidenceQuery {
    List<AlertNotificationEvidence> findNotificationEvidence(List<AlertTransitionId> transitionIds);
}
