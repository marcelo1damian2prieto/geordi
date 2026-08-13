package io.geordi.metrics.adapter.out.victoriametrics;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.metrics.application.MetricsBackendException;
import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.application.port.out.MetricsBackendProbe;
import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

public final class VictoriaMetricsAdapter implements MetricsQueryPort, MetricsBackendProbe {

    private final RestClient client;
    private final VictoriaMetricsQueryTranslator translator = new VictoriaMetricsQueryTranslator();
    private final VictoriaMetricsResponseParser parser = new VictoriaMetricsResponseParser();

    public VictoriaMetricsAdapter(RestClient client) {
        this.client = client;
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        try {
            JsonNode body = client.get().uri(builder -> builder.path("/api/v1/series")
                            .queryParam("match[]", "{selector}")
                            .queryParam("start", DateTimeFormatter.ISO_INSTANT.format(range.from()))
                            .queryParam("end", DateTimeFormatter.ISO_INSTANT.format(range.to()))
                            .build(Map.of(
                                    "selector", "{\"geordi.telemetry.origin\"=\"monitored\"}")))
                    .retrieve().body(JsonNode.class);
            return parser.services(body);
        } catch (RestClientException | IllegalArgumentException exception) {
            throw failure(exception);
        }
    }

    @Override
    public List<MetricSeries> query(MetricsQuery query) {
        List<MetricSeries> result = new ArrayList<>();
        try {
            for (var metric : query.metrics()) {
                JsonNode body = client.get().uri(builder -> builder.path("/api/v1/query_range")
                                .queryParam("query", "{expression}")
                                .queryParam("start", DateTimeFormatter.ISO_INSTANT.format(query.range().from()))
                                .queryParam("end", DateTimeFormatter.ISO_INSTANT.format(query.range().to()))
                                .queryParam("step", query.resolution().toSeconds())
                                .build(Map.of("expression", translator.translate(query, metric))))
                        .retrieve().body(JsonNode.class);
                result.add(parser.series(body, metric));
            }
            return List.copyOf(result);
        } catch (RestClientException | IllegalArgumentException exception) {
            throw failure(exception);
        }
    }

    @Override
    public boolean isQueryable() {
        try {
            JsonNode body = client.get().uri(builder -> builder.path("/api/v1/query")
                            .queryParam("query", "1").build())
                    .retrieve().body(JsonNode.class);
            return parser.scalarIsOne(body);
        } catch (RestClientException | MetricsBackendException | IllegalArgumentException exception) {
            return false;
        }
    }

    private static MetricsBackendException failure(RuntimeException cause) {
        return new MetricsBackendException("Metrics backend query failed", cause);
    }
}
