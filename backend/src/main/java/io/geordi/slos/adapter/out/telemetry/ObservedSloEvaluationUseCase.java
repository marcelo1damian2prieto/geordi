package io.geordi.slos.adapter.out.telemetry;

import io.geordi.slos.application.SloEvaluationUseCase;
import io.geordi.slos.domain.SloEvaluation;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributesBuilder;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import java.util.Locale;
import java.util.Objects;

public final class ObservedSloEvaluationUseCase implements SloEvaluationUseCase {

    private static final AttributeKey<String> STATUS = AttributeKey.stringKey("geordi.slo.status");
    private static final AttributeKey<String> SLI_TYPE = AttributeKey.stringKey("geordi.slo.sli_type");
    private static final AttributeKey<String> REASON = AttributeKey.stringKey("geordi.slo.reason");

    private final SloEvaluationUseCase delegate;
    private final LongCounter evaluations;
    private final LongCounter results;
    private final LongCounter failures;
    private final DoubleHistogram duration;

    public ObservedSloEvaluationUseCase(SloEvaluationUseCase delegate) {
        this.delegate = Objects.requireNonNull(delegate, "SLO evaluation delegate must not be null");
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.slos");
        evaluations = meter.counterBuilder("geordi.slo.evaluations").build();
        results = meter.counterBuilder("geordi.slo.results").build();
        failures = meter.counterBuilder("geordi.slo.failures").build();
        duration = meter.histogramBuilder("geordi.slo.duration").setUnit("s").build();
    }

    @Override
    public SloEvaluation evaluate(String id) {
        evaluations.add(1);
        long started = System.nanoTime();
        try {
            SloEvaluation result = delegate.evaluate(id);
            AttributesBuilder attributes = Attributes.builder()
                    .put(STATUS, lower(result.status().name()))
                    .put(SLI_TYPE, lower(result.sliType().name()));
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
