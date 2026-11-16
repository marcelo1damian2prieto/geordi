package io.geordi.selfobservability.adapter.security.export;

import io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizer;
import io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizerProvider;

/** Loaded by the agent from the thin extension JAR before any span export. */
public final class SecurityTelemetryExtension implements AutoConfigurationCustomizerProvider {
    @Override
    public void customize(AutoConfigurationCustomizer customizer) {
        customizer.addSpanExporterCustomizer((exporter, properties) -> new SecuritySpanExporter(exporter));
    }
}
