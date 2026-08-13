package io.geordi.metrics.adapter.out.victoriametrics;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.metrics.application.MetricsBackendException;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

final class VictoriaMetricsResponseParser {

    List<ServiceIdentity> services(JsonNode root) {
        ensureSuccess(root);
        List<ServiceIdentity> services = new ArrayList<>();
        for (JsonNode item : root.path("data")) {
            String name = text(item, "service.name");
            String environment = text(item, "deployment.environment.name");
            if (name != null && environment != null
                    && "monitored".equals(text(item, "geordi.telemetry.origin"))) {
                services.add(new ServiceIdentity(name, text(item, "service.namespace"), environment));
            }
        }
        return services;
    }

    MetricSeries series(JsonNode root, OperationalMetric metric) {
        ensureSuccess(root);
        List<MetricPoint> points = new ArrayList<>();
        for (JsonNode result : root.path("data").path("result")) {
            for (JsonNode value : result.path("values")) {
                if (value.isArray() && value.size() >= 2) {
                    double parsed = value.get(1).asDouble(Double.NaN);
                    if (Double.isFinite(parsed)) {
                        points.add(new MetricPoint(
                                Instant.ofEpochMilli(Math.round(value.get(0).asDouble() * 1000)), parsed));
                    }
                }
            }
        }
        return new MetricSeries(metric, points);
    }

    boolean scalarIsOne(JsonNode root) {
        ensureSuccess(root);
        JsonNode result = root.path("data").path("result");
        return result.isArray() && !result.isEmpty()
                && "1".equals(result.get(0).path("value").path(1).asText());
    }

    private static void ensureSuccess(JsonNode root) {
        if (root == null || !"success".equals(root.path("status").asText())) {
            throw new MetricsBackendException("Metrics backend returned an invalid response");
        }
    }

    private static String text(JsonNode node, String field) {
        String value = node.path(field).asText(null);
        return value == null || value.isBlank() ? null : value;
    }
}
