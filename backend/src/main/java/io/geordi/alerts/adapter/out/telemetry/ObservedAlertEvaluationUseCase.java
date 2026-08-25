package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.AlertEvaluationUseCase;
import io.geordi.alerts.domain.AlertEvaluation;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributesBuilder;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Locale;
import java.util.Objects;

public final class ObservedAlertEvaluationUseCase implements AlertEvaluationUseCase {

    private static final AttributeKey<String> CONDITION_TYPE =
            AttributeKey.stringKey("geordi.alert.condition.type");
    private static final AttributeKey<String> STATUS = AttributeKey.stringKey("geordi.alert.status");
    private static final AttributeKey<String> REASON = AttributeKey.stringKey("geordi.alert.reason");

    private final AlertEvaluationUseCase delegate;
    private final LongCounter attempts;
    private final LongCounter results;
    private final LongCounter failures;
    private final DoubleHistogram duration;

    public ObservedAlertEvaluationUseCase(AlertEvaluationUseCase delegate) {
        this.delegate = Objects.requireNonNull(delegate, "alert evaluation delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.alerts");
        attempts = meter.counterBuilder("geordi.alert.evaluations").build();
        results = meter.counterBuilder("geordi.alert.results").build();
        failures = meter.counterBuilder("geordi.alert.failures").build();
        duration = meter.histogramBuilder("geordi.alert.duration").setUnit("s").build();
    }

    @Override
    public AlertEvaluation evaluate(String policyId) {
        attempts.add(1);
        long started = System.nanoTime();
        try {
            AlertEvaluation result = delegate.evaluate(policyId);
            AttributesBuilder attributes = Attributes.builder()
                    .put(CONDITION_TYPE, lower(result.condition().type().name()))
                    .put(STATUS, lower(result.status().name()));
            if (result.reason() != null) {
                attributes.put(REASON, lower(result.reason().name()));
            }
            results.add(1, attributes.build());
            return result;
        } catch (RuntimeException exception) {
            failures.add(1);
            throw exception;
        } finally {
            duration.record((System.nanoTime() - started) / 1_000_000_000.0);
        }
    }

    private static String lower(String value) {
        return value.toLowerCase(Locale.ROOT);
    }
}
