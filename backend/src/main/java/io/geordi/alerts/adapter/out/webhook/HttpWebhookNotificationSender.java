package io.geordi.alerts.adapter.out.webhook;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.alerts.adapter.out.config.ConfigurationNotificationDestinationSelector;
import io.geordi.alerts.adapter.out.config.WebhookNotificationProperties;
import io.geordi.alerts.application.port.out.NotificationDeliverySender;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.NotificationDelivery;
import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;
import java.util.Objects;

public final class HttpWebhookNotificationSender implements NotificationDeliverySender {

    private final WebhookNotificationProperties properties;
    private final ObjectMapper objectMapper;
    private final HttpClient client;
    private final ConfigurationNotificationDestinationSelector destinations;

    public HttpWebhookNotificationSender(WebhookNotificationProperties properties, ObjectMapper objectMapper) {
        this(properties, objectMapper, HttpClient.newBuilder()
                .connectTimeout(properties.connectTimeout()).followRedirects(HttpClient.Redirect.NEVER).build());
    }

    HttpWebhookNotificationSender(
            WebhookNotificationProperties properties, ObjectMapper objectMapper, HttpClient client) {
        this.properties = Objects.requireNonNull(properties);
        this.objectMapper = Objects.requireNonNull(objectMapper);
        this.client = Objects.requireNonNull(client);
        this.destinations = new ConfigurationNotificationDestinationSelector(properties);
    }

    @Override
    public Result send(NotificationDelivery delivery) {
        var configured = destinations.selectFor(delivery.transition());
        if (configured.isEmpty() || !configured.orElseThrow().equals(delivery.destination())) {
            return Result.TERMINAL_FAILURE;
        }
        try {
            HttpRequest request = HttpRequest.newBuilder(properties.endpoint())
                    .timeout(properties.readTimeout())
                    .header("Content-Type", "application/json")
                    .header("Idempotency-Key", delivery.id())
                    .header(properties.tokenHeader(), properties.token())
                    .POST(HttpRequest.BodyPublishers.ofString(payload(delivery)))
                    .build();
            int status = client.send(request, HttpResponse.BodyHandlers.discarding()).statusCode();
            if (status >= 200 && status < 300) {
                return Result.DELIVERED;
            }
            return status == 429 || status >= 500 ? Result.RETRYABLE_FAILURE : Result.TERMINAL_FAILURE;
        } catch (IOException exception) {
            return Result.RETRYABLE_FAILURE;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return Result.RETRYABLE_FAILURE;
        }
    }

    private String payload(NotificationDelivery delivery) throws JsonProcessingException {
        AlertTransition transition = delivery.transition();
        var evaluation = transition.evaluation();
        var evidence = evaluation.evidence();
        Map<String, Object> payload = Map.ofEntries(
                Map.entry("schemaVersion", "geordi.notification.v1"),
                Map.entry("deliveryId", delivery.id()),
                Map.entry("transitionType", transition.type().name()),
                Map.entry("occurredAt", transition.occurredAt()),
                Map.entry("policy", Map.of("id", evaluation.policyId(), "name", evaluation.policyName())),
                Map.entry("sloId", evaluation.sloId()),
                Map.entry("condition", evaluation.condition()),
                Map.entry("service", evidence.service()),
                Map.entry("window", evidence.window().name()),
                Map.entry("range", evidence.range()),
                Map.entry("evaluatedAt", evidence.evaluatedAt()),
                Map.entry("observedBurnRate", evidence.observedBurnRate()));
        return objectMapper.writeValueAsString(payload);
    }
}
