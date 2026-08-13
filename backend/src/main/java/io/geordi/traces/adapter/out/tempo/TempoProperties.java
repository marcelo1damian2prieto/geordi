package io.geordi.traces.adapter.out.tempo;

import java.net.URI;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties("geordi.traces.tempo")
public record TempoProperties(URI baseUrl, Duration connectTimeout, Duration readTimeout) {

    public TempoProperties {
        baseUrl = baseUrl == null ? URI.create("http://localhost:3200") : baseUrl;
        connectTimeout = connectTimeout == null ? Duration.ofSeconds(2) : connectTimeout;
        readTimeout = readTimeout == null ? Duration.ofSeconds(3) : readTimeout;
        if (connectTimeout.isZero() || connectTimeout.isNegative()
                || readTimeout.isZero() || readTimeout.isNegative()) {
            throw new IllegalArgumentException("Tempo timeouts must be positive");
        }
    }
}
