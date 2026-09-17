package io.geordi.alerts.adapter.out.webhook;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertRoutingAdapter;
import io.geordi.alerts.adapter.out.config.WebhookNotificationProperties;
import io.geordi.alerts.application.port.out.NotificationDeliverySender;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.BurnRateBandResult;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
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
        if (transition.evaluation().condition() instanceof BurnRateAboveCondition
                && transition.evaluation().evidence() instanceof BurnRateEvidence evidence) {
            return objectMapper.writeValueAsString(legacyPayload(delivery, transition, evidence));
        }
        if (transition.evaluation().condition() instanceof MultiwindowBurnRateCondition condition
                && transition.evaluation().evidence() instanceof MultiwindowBurnRateEvidence evidence) {
            return objectMapper.writeValueAsString(multiwindowPayload(delivery, transition, condition, evidence));
        }
        throw new JsonProcessingException("unsupported persisted alert transition") { };
    }

    private ObjectNode legacyPayload(
            NotificationDelivery delivery, AlertTransition transition, BurnRateEvidence evidence) {
        var evaluation = transition.evaluation();
        ObjectNode payload = commonPayload(delivery, transition, "geordi.notification.v1");
        payload.set("condition", legacyCondition((BurnRateAboveCondition) evaluation.condition()));
        payload.set("service", service(evidence.service()));
        payload.put("window", evidence.window().name());
        payload.set("range", range(evidence.range()));
        payload.set("evaluatedAt", objectMapper.valueToTree(evidence.evaluatedAt()));
        payload.put("observedBurnRate", evidence.observedBurnRate());
        return payload;
    }

    private ObjectNode multiwindowPayload(
            NotificationDelivery delivery,
            AlertTransition transition,
            MultiwindowBurnRateCondition condition,
            MultiwindowBurnRateEvidence evidence) {
        var evaluation = transition.evaluation();
        ObjectNode payload = commonPayload(delivery, transition, "geordi.notification.v2");
        payload.set("condition", multiwindowCondition(condition));
        payload.put("evaluationStatus", evaluation.status().name());
        if (evaluation.reason() == null) {
            payload.putNull("reason");
        } else {
            payload.put("reason", evaluation.reason().name());
        }
        payload.set("service", service(evidence.service()));
        payload.put("configuredSloWindow", evidence.configuredSloWindow().name());
        payload.set("evaluatedAt", objectMapper.valueToTree(evidence.evaluatedAt()));
        ArrayNode observations = payload.putArray("observations");
        evidence.observations().forEach(value -> observations.add(observation(value)));
        ArrayNode results = payload.putArray("bandResults");
        evaluation.bandResults().forEach(value -> results.add(bandResult(value)));
        return payload;
    }

    private ObjectNode commonPayload(
            NotificationDelivery delivery, AlertTransition transition, String schemaVersion) {
        var evaluation = transition.evaluation();
        ObjectNode payload = objectMapper.createObjectNode();
        payload.put("schemaVersion", schemaVersion);
        payload.put("deliveryId", delivery.id());
        payload.put("transitionType", transition.type().name());
        payload.set("occurredAt", objectMapper.valueToTree(transition.occurredAt()));
        ObjectNode policy = payload.putObject("policy");
        policy.put("id", evaluation.policyId());
        policy.put("name", evaluation.policyName());
        payload.put("sloId", evaluation.sloId());
        return payload;
    }

    private ObjectNode legacyCondition(BurnRateAboveCondition condition) {
        ObjectNode node = objectMapper.createObjectNode();
        node.put("type", condition.type().name());
        node.put("threshold", condition.threshold());
        return node;
    }

    private ObjectNode multiwindowCondition(MultiwindowBurnRateCondition condition) {
        ObjectNode node = objectMapper.createObjectNode();
        node.put("type", condition.type().name());
        ArrayNode bands = node.putArray("bands");
        condition.bands().forEach(value -> bands.add(band(value)));
        return node;
    }

    private ObjectNode band(BurnRateBand value) {
        ObjectNode node = objectMapper.createObjectNode();
        node.put("longWindow", value.longWindow().name());
        node.put("shortWindow", value.shortWindow().name());
        node.put("threshold", value.threshold());
        return node;
    }

    private ObjectNode observation(WindowBurnRateObservation value) {
        ObjectNode node = objectMapper.createObjectNode();
        node.put("observationWindow", value.observationWindow().name());
        node.set("range", range(value.range()));
        if (value.observedBurnRate() == null) {
            node.putNull("observedBurnRate");
        } else {
            node.put("observedBurnRate", value.observedBurnRate());
        }
        if (value.reason() == null) {
            node.putNull("reason");
        } else {
            node.put("reason", value.reason().name());
        }
        return node;
    }

    private ObjectNode bandResult(BurnRateBandResult value) {
        ObjectNode node = objectMapper.createObjectNode();
        node.set("band", band(value.band()));
        node.set("longObservation", observation(value.longObservation()));
        node.set("shortObservation", observation(value.shortObservation()));
        node.put("outcome", value.outcome().name());
        return node;
    }

    private ObjectNode service(io.geordi.alerts.domain.ServiceIdentity value) {
        ObjectNode node = objectMapper.createObjectNode();
        node.put("name", value.name());
        node.put("namespace", value.namespace());
        node.put("environment", value.environment());
        return node;
    }

    private ObjectNode range(TimeRange value) {
        ObjectNode node = objectMapper.createObjectNode();
        node.set("from", objectMapper.valueToTree(value.from()));
        node.set("to", objectMapper.valueToTree(value.to()));
        return node;
    }
}
