package io.geordi.alerts.adapter.in.worker;

import io.geordi.alerts.adapter.out.config.WebhookNotificationProperties;
import io.geordi.alerts.application.NotificationDeliveryWorkService;
import io.geordi.alerts.application.port.out.NotificationDeliverySender;
import io.geordi.alerts.domain.NotificationDelivery;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.time.Clock;
import java.time.Duration;
import java.util.Locale;
import org.springframework.scheduling.annotation.Scheduled;

public final class NotificationDeliveryWorker {

    private static final System.Logger LOGGER = System.getLogger(NotificationDeliveryWorker.class.getName());
    private static final AttributeKey<String> OUTCOME = AttributeKey.stringKey("geordi.alert.delivery.outcome");
    private static final AttributeKey<String> TRANSITION =
            AttributeKey.stringKey("geordi.alert.delivery.transition.type");
    private final NotificationDeliveryWorkService work;
    private final NotificationDeliverySender sender;
    private final WebhookNotificationProperties properties;
    private final Clock clock;
    private final LongCounter attempts;
    private final LongCounter results;
    private final LongCounter retries;
    private final LongCounter failures;
    private final DoubleHistogram duration;

    public NotificationDeliveryWorker(NotificationDeliveryWorkService work, NotificationDeliverySender sender,
            WebhookNotificationProperties properties, Clock clock) {
        this.work = work;
        this.sender = sender;
        this.properties = properties;
        this.clock = clock;
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.alerts");
        attempts = meter.counterBuilder("geordi.alert.delivery.attempts").build();
        results = meter.counterBuilder("geordi.alert.delivery.results").build();
        retries = meter.counterBuilder("geordi.alert.delivery.retries").build();
        failures = meter.counterBuilder("geordi.alert.delivery.failures").build();
        duration = meter.histogramBuilder("geordi.alert.delivery.duration").setUnit("s").build();
    }

    @Scheduled(fixedDelayString = "${geordi.notification.poll-interval:1s}")
    public void processDue() {
        for (NotificationDelivery delivery : work.claimDue(
                properties.batchSize(), properties.leaseDuration(), properties.maximumAttempts())) {
            process(delivery);
        }
    }

    private void process(NotificationDelivery delivery) {
        long started = System.nanoTime();
        attempts.add(1);
        try {
            NotificationDeliverySender.Result result = sender.send(delivery);
            String outcome = "unexpected";
            switch (result) {
                case DELIVERED -> {
                    work.markDelivered(delivery);
                    outcome = "delivered";
                }
                case TERMINAL_FAILURE -> {
                    work.markFailed(delivery);
                    outcome = "terminal_failure";
                }
                case RETRYABLE_FAILURE -> {
                    Duration delay = delivery.attempts() == 1 ? Duration.ofSeconds(1) : Duration.ofSeconds(5);
                    work.retryOrFail(delivery, clock.instant().plus(delay), properties.maximumAttempts());
                    boolean exhausted = delivery.attempts() >= properties.maximumAttempts();
                    outcome = exhausted ? "exhausted" : "retry_scheduled";
                    if (!exhausted) retries.add(1);
                }
            }
            results.add(1, Attributes.of(
                    OUTCOME, outcome,
                    TRANSITION, delivery.transition().type().name().toLowerCase(Locale.ROOT)));
        } catch (RuntimeException exception) {
            failures.add(1);
            LOGGER.log(System.Logger.Level.ERROR, "notification delivery processing failed");
        } finally {
            duration.record((System.nanoTime() - started) / 1_000_000_000.0);
        }
    }
}
