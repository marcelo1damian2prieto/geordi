package io.geordi.alerts.adapter.out.webhook;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertRoutingAdapter;
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

    private final ObjectMapper objectMapper;
    private final HttpClient client;
    private final ConfigurationAlertRoutingAdapter destinations;
    private final WebhookNotificationProperties deliveryProperties;

    public HttpWebhookNotificationSender(ConfigurationAlertRoutingAdapter destinations, ObjectMapper objectMapper) {
        this(destinations, new WebhookNotificationProperties(false, null, null, null, null, null,
                java.time.Duration.ofSeconds(1), java.time.Duration.ofSeconds(2), java.time.Duration.ofSeconds(1),
                java.time.Duration.ofSeconds(10), 10, 3, false), objectMapper);
    }

    public HttpWebhookNotificationSender(ConfigurationAlertRoutingAdapter destinations,
            WebhookNotificationProperties deliveryProperties, ObjectMapper objectMapper) {
        this(destinations, deliveryProperties, objectMapper, HttpClient.newBuilder()
                .connectTimeout(deliveryProperties.connectTimeout()).followRedirects(HttpClient.Redirect.NEVER).build());
    }

    HttpWebhookNotificationSender(
            ConfigurationAlertRoutingAdapter destinations, WebhookNotificationProperties deliveryProperties,
            ObjectMapper objectMapper, HttpClient client) {
        this.objectMapper = Objects.requireNonNull(objectMapper);
        this.client = Objects.requireNonNull(client);
        this.destinations = Objects.requireNonNull(destinations);
        this.deliveryProperties = Objects.requireNonNull(deliveryProperties);
    }

    @Override
    public Result send(NotificationDelivery delivery) {
        var configured = destinations.resolveWebhookDestination(delivery.destination());
        if (configured.isEmpty()) {
            return Result.TERMINAL_FAILURE;
        }
        try {
            var endpoint = configured.orElseThrow().endpoint();
            var header = configured.orElseThrow().tokenHeader();
            var token = configured.orElseThrow().token();
            var requestBuilder = HttpRequest.newBuilder(endpoint)
                    .timeout(deliveryProperties.readTimeout())
                    .header("Content-Type", "application/json")
                    .header("Idempotency-Key", delivery.id())
                    .POST(HttpRequest.BodyPublishers.ofString(payload(delivery)));
            if (token != null) requestBuilder.header(header, token);
            HttpRequest request = requestBuilder.build();
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
