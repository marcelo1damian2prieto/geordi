package io.geordi.alerts.application;

import io.geordi.alerts.domain.AlertTransitionRecord;
import java.util.List;

public interface AlertNotificationProjectionQuery {
    List<AlertEpisodeTransition> project(List<AlertTransitionRecord> transitions);
}
