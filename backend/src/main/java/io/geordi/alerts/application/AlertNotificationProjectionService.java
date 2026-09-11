package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertNotificationEvidenceQuery;
import io.geordi.alerts.domain.AlertTransitionRecord;
import io.geordi.alerts.domain.NotificationDeliveryState;
import io.geordi.alerts.domain.NotificationDisposition;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import java.util.stream.Collectors;
import static io.geordi.alerts.application.AlertNotificationIntegrityException.Reason.*;

/** Combines immutable decision evidence and exactly correlated durable delivery state. */
public final class AlertNotificationProjectionService implements AlertNotificationProjectionQuery {
    private final AlertNotificationEvidenceQuery evidence;

    public AlertNotificationProjectionService(AlertNotificationEvidenceQuery evidence) {
        this.evidence = Objects.requireNonNull(evidence);
    }

    @Override
    public List<AlertEpisodeTransition> project(List<AlertTransitionRecord> transitions) {
        var rows = evidence.findNotificationEvidence(transitions.stream().map(AlertTransitionRecord::id).toList());
        var indexed = rows.stream().collect(Collectors.toMap(AlertNotificationEvidence::transitionId, Function.identity()));
        return transitions.stream().map(record -> new AlertEpisodeTransition(record,
                projectOne(record, indexed.get(record.id())))).toList();
    }

    private static AlertNotificationStatus projectOne(AlertTransitionRecord record, AlertNotificationEvidence row) {
        NotificationDisposition disposition = row == null ? null : row.disposition();
        AlertNotificationEvidence.Delivery delivery = row == null ? null : row.delivery();
        if (disposition == NotificationDisposition.MATCHED && delivery == null) {
            throw new AlertNotificationIntegrityException(MATCHED_DELIVERY_MISSING);
        }
        if ((disposition == NotificationDisposition.SUPPRESSED || disposition == NotificationDisposition.UNROUTED)
                && delivery != null) {
            throw new AlertNotificationIntegrityException(UNEXPECTED_DELIVERY);
        }
        if (delivery != null && (!record.id().value().equals(delivery.id())
                || !record.transition().equals(delivery.transition()))) {
            throw new AlertNotificationIntegrityException(CORRELATION_INVALID);
        }
        var value = disposition == null ? AlertNotificationStatus.Disposition.NOT_RECORDED
                : AlertNotificationStatus.Disposition.valueOf(disposition.name());
        return new AlertNotificationStatus(value, delivery == null ? null : projectDelivery(delivery));
    }

    private static AlertNotificationStatus.Delivery projectDelivery(AlertNotificationEvidence.Delivery delivery) {
        NotificationDeliveryState state = delivery.state();
        boolean terminal = state == NotificationDeliveryState.DELIVERED || state == NotificationDeliveryState.FAILED;
        if (state == null || delivery.attempts() < 0 || delivery.createdAt() == null || delivery.nextAttemptAt() == null
                || (state != NotificationDeliveryState.PENDING && delivery.attempts() < 1)
                || terminal != (delivery.completedAt() != null)) {
            throw new AlertNotificationIntegrityException(STORED_VALUE_INVALID);
        }
        return new AlertNotificationStatus.Delivery(state, delivery.attempts(), delivery.createdAt(),
                state == NotificationDeliveryState.PENDING ? delivery.nextAttemptAt() : null,
                terminal ? delivery.completedAt() : null);
    }
}
