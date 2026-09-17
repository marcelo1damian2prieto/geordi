package io.geordi.alerts.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.json.JsonMapper;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class AlertPersistenceJsonCodecTest {

    private static final Instant NOW = Instant.parse("2026-09-14T15:30:00.123456789Z");
    private final AlertPersistenceJsonCodec codec =
            new AlertPersistenceJsonCodec(JsonMapper.builder().findAndAddModules().build());

    @Test
    void roundTripsCanonicalMultiwindowLifecycleAndTransitionUsingExplicitV2Envelopes() {
        AlertLifecycle lifecycle = firingLifecycle();
        AlertTransition transition = lifecycle.latestTransition();

        String lifecycleJson = codec.writeLifecycle(lifecycle);
        String transitionJson = codec.writeTransition(transition);

        assertThat(lifecycleJson)
                .startsWith("{\"persistenceFormatVersion\":2,\"lifecycle\":{")
                .contains("\"type\":\"MULTIWINDOW_BURN_RATE\"")
                .contains("\"configuredSloWindow\":\"PT15M\"")
                .contains("\"observationWindow\":\"PT5M\"")
                .contains("\"observationWindow\":\"PT30M\"")
                .contains("\"observationWindow\":\"PT1H\"")
                .contains("\"observationWindow\":\"PT6H\"")
                .contains("\"bandResults\":[")
                .doesNotContain("requestCount", "errorCount", "providerQuery");
        assertThat(transitionJson).startsWith("{\"persistenceFormatVersion\":2,\"transition\":{");
        assertThat(codec.writeLifecycle(lifecycle)).isEqualTo(lifecycleJson);
        assertThat(codec.writeTransition(transition)).isEqualTo(transitionJson);
        assertThat(codec.readLifecycle(lifecycleJson)).isEqualTo(lifecycle);
        assertThat(codec.readTransition(transitionJson)).isEqualTo(transition);
    }

    @Test
    void rejectsStoredBandResultsThatDoNotMatchRecomputedEvidence() {
        String valid = codec.writeTransition(firingLifecycle().latestTransition());
        String tampered = valid.replace("\"outcome\":\"NOT_MET\"", "\"outcome\":\"MET\"");

        assertThat(tampered).isNotEqualTo(valid);
        assertThatThrownBy(() -> codec.readTransition(tampered))
                .isInstanceOf(AlertPersistenceJsonCodec.InvalidPersistenceJsonException.class)
                .hasMessage("invalid durable alert JSON");
    }

    @Test
    void rejectsNoncanonicalV2BandOrderInsteadOfSilentlyNormalizingDurableData() throws Exception {
        String valid = codec.writeTransition(firingLifecycle().latestTransition());
        var root = JsonMapper.builder().findAndAddModules().build().readTree(valid);
        var bands = (com.fasterxml.jackson.databind.node.ArrayNode) root.at(
                "/transition/evaluation/condition/bands");
        var first = bands.remove(0);
        bands.add(first);

        assertThatThrownBy(() -> codec.readTransition(root.toString()))
                .isInstanceOf(AlertPersistenceJsonCodec.InvalidPersistenceJsonException.class);
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "{\"persistenceFormatVersion\":null,\"transition\":{}}",
            "{\"persistenceFormatVersion\":\"2\",\"transition\":{}}",
            "{\"persistenceFormatVersion\":2.0,\"transition\":{}}",
            "{\"persistenceFormatVersion\":1,\"transition\":{}}",
            "{\"persistenceFormatVersion\":3,\"transition\":{}}",
            "{\"persistenceFormatVersion\":2,\"lifecycle\":{}}",
            "{\"persistenceFormatVersion\":2,\"transition\":{},\"unexpected\":true}",
            "{\"policyId\":\"one\",\"policyId\":\"two\"}",
            "{\"persistenceFormatVersion\":2,\"transition\":{}} {}",
            "{\"policyId\":\"one\"} {\"policyId\":\"two\"}"
    })
    void failsClosedForMalformedUnsupportedOrAmbiguousTransitionFormats(String json) {
        assertThatThrownBy(() -> codec.readTransition(json))
                .isInstanceOf(AlertPersistenceJsonCodec.InvalidPersistenceJsonException.class)
                .hasMessage("invalid durable alert JSON");
    }

    @Test
    void rejectsLegacyDomainInsideV2InsteadOfCreatingAmbiguousWebhookSemantics() throws Exception {
        String legacy = resource("transition-started-v1.json");
        String wrapped = "{\"persistenceFormatVersion\":2,\"transition\":" + legacy + '}';

        assertThatThrownBy(() -> codec.readTransition(wrapped))
                .isInstanceOf(AlertPersistenceJsonCodec.InvalidPersistenceJsonException.class);
    }

    private static AlertLifecycle firingLifecycle() {
        MultiwindowBurnRateCondition condition = condition();
        MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                "checkout-availability", new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT15M, NOW, condition.observationWindows(), List.of(
                        observation(AlertObservationWindow.PT6H, "5", null),
                        observation(AlertObservationWindow.PT1H, "15", null),
                        observation(AlertObservationWindow.PT30M, null, AlertUnavailableReason.METRICS_UNAVAILABLE),
                        observation(AlertObservationWindow.PT5M, "20", null)));
        AlertEvaluation evaluation = new AlertEvaluation(
                "checkout-multiwindow", "Checkout multiwindow", "checkout-availability", condition,
                AlertEvaluationStatus.CONDITION_MET, null, evidence);
        return AlertLifecycleTransitions.apply(Optional.empty(), evaluation, null).current();
    }

    private static MultiwindowBurnRateCondition condition() {
        return new MultiwindowBurnRateCondition(List.of(
                new BurnRateBand(AlertObservationWindow.PT6H, AlertObservationWindow.PT30M,
                        new BigDecimal("6.00")),
                new BurnRateBand(AlertObservationWindow.PT1H, AlertObservationWindow.PT5M,
                        new BigDecimal("14.40"))));
    }

    private static WindowBurnRateObservation observation(
            AlertObservationWindow window, String burnRate, AlertUnavailableReason reason) {
        return new WindowBurnRateObservation(
                window, new TimeRange(NOW.minus(window.duration()), NOW),
                burnRate == null ? null : new BigDecimal(burnRate), reason);
    }

    private static String resource(String name) throws Exception {
        try (var stream = AlertPersistenceJsonCodecTest.class.getResourceAsStream(
                "/io/geordi/alerts/adapter/out/persistence/compatibility/" + name)) {
            return new String(java.util.Objects.requireNonNull(stream).readAllBytes(),
                    java.nio.charset.StandardCharsets.UTF_8).stripTrailing();
        }
    }
}
