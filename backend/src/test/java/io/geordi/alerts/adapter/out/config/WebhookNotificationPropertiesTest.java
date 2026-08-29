package io.geordi.alerts.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.domain.AlertTransitionType;
import java.net.URI;
import java.time.Duration;
import java.util.List;
import org.junit.jupiter.api.Test;

class WebhookNotificationPropertiesTest {

    @Test
    void acceptsBoundedHttpsConfigurationAndSelectsConfiguredTransitions() {
        var properties = properties(URI.create("https://hooks.example.test/geordi"), false);
        var selector = new ConfigurationNotificationDestinationSelector(properties);
        var transition = io.geordi.alerts.domain.AlertLifecycleTransitions.apply(
                java.util.Optional.empty(), TestAlertEvaluations.met(), null).transition();

        assertThat(selector.selectFor(transition)).isPresent().get()
                .extracting(destination -> destination.id()).isEqualTo("primary-webhook");
        assertThat(transition.type()).isEqualTo(AlertTransitionType.ALERT_STARTED);
    }

    @Test
    void rejectsPlainHttpOutsideExplicitLocalFixture() {
        assertThatThrownBy(() -> properties(URI.create("http://external.example.test/hook"), true))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("notification endpoint must use HTTPS");
    }

    @Test
    void rejectsTimeoutThatCanOutliveLease() {
        assertThatThrownBy(() -> new WebhookNotificationProperties(
                true, "primary-webhook", URI.create("https://hooks.example.test/geordi"), "secret",
                "X-Geordi-Token", List.of("ALERT_STARTED"), Duration.ofSeconds(1), Duration.ofSeconds(10),
                Duration.ofSeconds(1), Duration.ofSeconds(10), 10, 3, false))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("notification read timeout must be shorter than lease duration");
    }

    @Test
    void rejectsInvalidOrReservedTokenHeaderAtStartup() {
        assertThatThrownBy(() -> new WebhookNotificationProperties(
                true, "primary-webhook", URI.create("https://hooks.example.test/geordi"), "secret",
                "bad header", List.of("ALERT_STARTED"), Duration.ofSeconds(1), Duration.ofSeconds(2),
                Duration.ofSeconds(1), Duration.ofSeconds(10), 10, 3, false))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("notification token header is invalid");
        for (String reserved : List.of("Connection", "Expect", "Upgrade", "Idempotency-Key")) {
            assertThatThrownBy(() -> new WebhookNotificationProperties(
                    true, "primary-webhook", URI.create("https://hooks.example.test/geordi"), "secret",
                    reserved, List.of("ALERT_STARTED"), Duration.ofSeconds(1), Duration.ofSeconds(2),
                    Duration.ofSeconds(1), Duration.ofSeconds(10), 10, 3, false))
                    .isInstanceOf(IllegalArgumentException.class)
                    .hasMessage("notification token header is invalid");
        }
    }

    private static WebhookNotificationProperties properties(URI endpoint, boolean insecureLocal) {
        return new WebhookNotificationProperties(
                true, "primary-webhook", endpoint, "secret", "X-Geordi-Token",
                List.of("ALERT_STARTED", "ALERT_RESOLVED"), Duration.ofSeconds(1), Duration.ofSeconds(2),
                Duration.ofSeconds(1), Duration.ofSeconds(10), 10, 3, insecureLocal);
    }
}
