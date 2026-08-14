package io.geordi.logs.adapter.out.loki;

import java.net.URI;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties("geordi.logs.loki")
public record LokiProperties(URI baseUrl, Duration connectTimeout, Duration readTimeout) {

    public LokiProperties {
        baseUrl = baseUrl == null ? URI.create("http://localhost:3100") : baseUrl;
        connectTimeout = connectTimeout == null ? Duration.ofSeconds(2) : connectTimeout;
        readTimeout = readTimeout == null ? Duration.ofSeconds(3) : readTimeout;
        if (connectTimeout.isZero() || connectTimeout.isNegative()
                || readTimeout.isZero() || readTimeout.isNegative()) {
            throw new IllegalArgumentException("Loki timeouts must be positive");
        }
    }
}
