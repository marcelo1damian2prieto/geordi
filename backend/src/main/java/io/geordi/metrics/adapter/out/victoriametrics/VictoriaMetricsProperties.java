package io.geordi.metrics.adapter.out.victoriametrics;

import java.net.URI;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties("geordi.metrics.victoria-metrics")
public record VictoriaMetricsProperties(URI baseUrl, Duration connectTimeout, Duration readTimeout) {

    public VictoriaMetricsProperties {
        baseUrl = baseUrl == null ? URI.create("http://localhost:8428") : baseUrl;
        connectTimeout = connectTimeout == null ? Duration.ofSeconds(2) : connectTimeout;
        readTimeout = readTimeout == null ? Duration.ofSeconds(5) : readTimeout;
        if (connectTimeout.isNegative() || connectTimeout.isZero()
                || readTimeout.isNegative() || readTimeout.isZero()) {
            throw new IllegalArgumentException("VictoriaMetrics timeouts must be positive");
        }
    }
}
