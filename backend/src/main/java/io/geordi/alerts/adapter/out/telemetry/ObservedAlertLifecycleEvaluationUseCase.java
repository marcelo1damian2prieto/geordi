package io.geordi.alerts.adapter.out.telemetry;

import io.geordi.alerts.application.AlertLifecycleEvaluationResult;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributesBuilder;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Locale;
import java.util.Objects;

public final class ObservedAlertLifecycleEvaluationUseCase implements AlertLifecycleEvaluationUseCase {

    private static final AttributeKey<String> OUTCOME =
            AttributeKey.stringKey("geordi.alert.lifecycle.outcome");
    private static final AttributeKey<String> STATE =
            AttributeKey.stringKey("geordi.alert.lifecycle.state");
    private static final AttributeKey<String> STATUS =
            AttributeKey.stringKey("geordi.alert.lifecycle.evaluation.status");
    private static final AttributeKey<String> REASON =
            AttributeKey.stringKey("geordi.alert.lifecycle.evaluation.reason");
    private static final AttributeKey<String> TRANSITION =
            AttributeKey.stringKey("geordi.alert.lifecycle.transition.type");

    private final AlertLifecycleEvaluationUseCase delegate;
    private final LongCounter attempts;
    private final LongCounter results;
    private final LongCounter transitions;
    private final LongCounter failures;
    private final DoubleHistogram duration;

    public ObservedAlertLifecycleEvaluationUseCase(AlertLifecycleEvaluationUseCase delegate) {
        this.delegate = Objects.requireNonNull(delegate, "alert lifecycle delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.alerts");
        attempts = meter.counterBuilder("geordi.alert.lifecycle.evaluations").build();
        results = meter.counterBuilder("geordi.alert.lifecycle.results").build();
        transitions = meter.counterBuilder("geordi.alert.lifecycle.transitions").build();
        failures = meter.counterBuilder("geordi.alert.lifecycle.failures").build();
        duration = meter.histogramBuilder("geordi.alert.lifecycle.duration").setUnit("s").build();
    }

    @Override
    public AlertLifecycleEvaluationResult evaluate(String policyId) {
        attempts.add(1);
        long started = System.nanoTime();
        try {
            AlertLifecycleEvaluationResult result = delegate.evaluate(policyId);
            AttributesBuilder attributes = Attributes.builder()
                    .put(OUTCOME, lower(result.outcome().name()))
                    .put(STATE, lower(result.current().state().name()))
                    .put(STATUS, lower(result.triggeringEvaluation().status().name()));
            if (result.triggeringEvaluation().reason() != null) {
                attributes.put(REASON, lower(result.triggeringEvaluation().reason().name()));
            }
            results.add(1, attributes.build());
            if (result.transition() != null) {
                transitions.add(1, Attributes.of(TRANSITION, lower(result.transition().type().name())));
            }
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
