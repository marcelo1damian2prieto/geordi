package io.geordi.alerts.adapter.out.webhook;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import io.geordi.alerts.adapter.out.config.AlertRoutingProperties;
import io.geordi.alerts.adapter.out.config.ConfigurationAlertRoutingAdapter;
import io.geordi.alerts.adapter.out.config.WebhookNotificationProperties;
import io.geordi.alerts.application.port.out.NotificationDeliverySender;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.net.InetSocketAddress;
import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

class HttpWebhookNotificationSenderTest {

    private HttpServer server;

    @AfterEach
    void stop() {
        if (server != null) server.stop(0);
    }

    @Test
    void classifiesHttpResponsesAndSendsStableIdentityAndVersionedPayload() throws Exception {
        AtomicReference<String> idempotency = new AtomicReference<>();
        AtomicReference<String> body = new AtomicReference<>();
        AtomicReference<Integer> status = new AtomicReference<>(204);
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/hook", exchange -> {
            idempotency.set(exchange.getRequestHeaders().getFirst("Idempotency-Key"));
            body.set(new String(exchange.getRequestBody().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8));
            exchange.sendResponseHeaders(status.get(), -1);
            exchange.close();
        });
        server.start();
        var properties = properties(server.getAddress().getPort());
        var delivery = delivery(properties);
        var sender = sender(properties);

        assertThat(sender.send(delivery)).isEqualTo(NotificationDeliverySender.Result.DELIVERED);
        assertThat(idempotency).hasValue(delivery.id());
        assertThat(body.get()).contains("geordi.notification.v1", delivery.id(), "ALERT_STARTED")
                .contains("observedBurnRate")
                .doesNotContain("test-token");

        status.set(429);
        assertThat(sender.send(delivery)).isEqualTo(NotificationDeliverySender.Result.RETRYABLE_FAILURE);
        status.set(503);
        assertThat(sender.send(delivery)).isEqualTo(NotificationDeliverySender.Result.RETRYABLE_FAILURE);
        status.set(400);
        assertThat(sender.send(delivery)).isEqualTo(NotificationDeliverySender.Result.TERMINAL_FAILURE);
    }

    @Test
    void classifiesConnectionFailureAndTimeoutAsRetryable() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/hook", exchange -> {
            try { Thread.sleep(250); } catch (InterruptedException exception) { Thread.currentThread().interrupt(); }
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
        });
        server.start();
        int port = server.getAddress().getPort();
        var timeoutProperties = new WebhookNotificationProperties(true, "primary",
                URI.create("http://localhost:" + port + "/hook"), "test-token", "X-Geordi-Token",
                List.of("ALERT_STARTED"), Duration.ofMillis(50), Duration.ofMillis(50),
                Duration.ofSeconds(1), Duration.ofSeconds(1), 10, 3, true);
        assertThat(sender(timeoutProperties)
                .send(delivery(timeoutProperties))).isEqualTo(NotificationDeliverySender.Result.RETRYABLE_FAILURE);

        server.stop(0);
        server = null;
        var connectionProperties = properties(port);
        assertThat(sender(connectionProperties)
                .send(delivery(connectionProperties))).isEqualTo(NotificationDeliverySender.Result.RETRYABLE_FAILURE);
    }

    @Test
    void failsIncompatiblePersistedDestinationWithoutRerouting() {
        var original = properties(6553);
        var changed = new WebhookNotificationProperties(
                true, "primary", original.endpoint(), "test-token", "X-Changed-Token",
                original.transitions(), original.connectTimeout(), original.readTimeout(), original.pollInterval(),
                original.leaseDuration(), original.batchSize(), original.maximumAttempts(), true);

        assertThat(sender(changed)
                .send(delivery(original))).isEqualTo(NotificationDeliverySender.Result.TERMINAL_FAILURE);
    }

    private static NotificationDelivery delivery(WebhookNotificationProperties properties) {
        Instant now = Instant.parse("2026-08-28T12:00:00Z");
        AlertCondition condition = new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE);
        BurnRateEvidence evidence = new BurnRateEvidence("slo", new ServiceIdentity("service", "namespace", "prod"),
                EvaluationWindow.PT5M, new TimeRange(now.minusSeconds(300), now), now, BigDecimal.TEN, null);
        AlertEvaluation evaluation = new AlertEvaluation("policy", "Policy", "slo", condition,
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
        var transition = AlertLifecycleTransitions.apply(Optional.empty(), evaluation, null).transition();
        var destination = ((io.geordi.alerts.domain.RoutingDecision.Matched) adapter(properties)
                .route(transition)).destination();
        return NotificationDelivery.pending(transition, destination, now);
    }

    private static HttpWebhookNotificationSender sender(WebhookNotificationProperties properties) {
        return new HttpWebhookNotificationSender(adapter(properties), properties, new ObjectMapper().findAndRegisterModules());
    }

    private static ConfigurationAlertRoutingAdapter adapter(WebhookNotificationProperties properties) {
        var destination = new AlertRoutingProperties.DestinationSettings("primary", properties.endpoint(),
                properties.token(), properties.tokenHeader());
        var route = new AlertRoutingProperties.RouteSettings("default", null, null, null, null,
                null, "DELIVER", "primary");
        return new ConfigurationAlertRoutingAdapter(new AlertRoutingProperties(List.of(destination), List.of(route), true),
                new io.geordi.alerts.application.port.out.AlertPolicyCatalog() {
                    @Override public List<io.geordi.alerts.domain.AlertPolicy> findAll() { return List.of(); }
                    @Override public Optional<io.geordi.alerts.domain.AlertPolicy> findById(String id) { return Optional.empty(); }
                });
    }

    private static WebhookNotificationProperties properties(int port) {
        return new WebhookNotificationProperties(true, "primary", URI.create("http://localhost:" + port + "/hook"),
                "test-token", "X-Geordi-Token", List.of("ALERT_STARTED", "ALERT_RESOLVED"),
                Duration.ofSeconds(1), Duration.ofSeconds(2), Duration.ofSeconds(1), Duration.ofSeconds(10),
                10, 3, true);
    }
}
