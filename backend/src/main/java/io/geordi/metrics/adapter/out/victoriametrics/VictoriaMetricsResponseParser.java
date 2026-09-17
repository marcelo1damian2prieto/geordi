package io.geordi.metrics.adapter.out.victoriametrics;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.metrics.application.MetricsBackendException;
import io.geordi.metrics.application.RequestOutcomeMeasurement;
import io.geordi.metrics.application.RequestOutcomeBatchMeasurement;
import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

final class VictoriaMetricsResponseParser {

    private static final String SLO_COMPONENT = "geordi.slo.component";
    private static final String SLO_WINDOW = "geordi.slo.window";

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

    RequestOutcomeMeasurement requestOutcomes(JsonNode root) {
        ensureSuccessForOutcomes(root);
        Double requests = null;
        Double errors = null;
        for (JsonNode result : root.path("data").path("result")) {
            String component = result.path("metric").path(SLO_COMPONENT).asText(null);
            double value = result.path("value").path(1).asDouble(Double.NaN);
            if (!Double.isFinite(value)) {
                throw invalidOutcomes();
            }
            if ("requests".equals(component) && requests == null) {
                requests = value;
            } else if ("errors".equals(component) && errors == null) {
                errors = value;
            } else {
                throw invalidOutcomes();
            }
        }
        if (requests != null && errors == null) {
            errors = 0d;
        }
        return new RequestOutcomeMeasurement(requests, errors);
    }

    RequestOutcomeBatchMeasurement requestOutcomeBatch(JsonNode root, List<String> requestedKeys) {
        ensureSuccessForOutcomes(root);
        Set<String> requested = Set.copyOf(requestedKeys);
        if (requested.size() != requestedKeys.size()) {
            throw integrityFailure();
        }
        Map<String, MutableOutcome> values = new LinkedHashMap<>();
        requestedKeys.forEach(key -> values.put(key, new MutableOutcome()));
        for (JsonNode result : root.path("data").path("result")) {
            String key = result.path("metric").path(SLO_WINDOW).asText(null);
            String component = result.path("metric").path(SLO_COMPONENT).asText(null);
            if (key == null || !requested.contains(key)
                    || !("requests".equals(component) || "errors".equals(component))) {
                throw integrityFailure();
            }
            MutableOutcome outcome = values.get(key);
            double value = result.path("value").path(1).asDouble(Double.NaN);
            if ("requests".equals(component)) {
                if (outcome.requestsSeen) {
                    throw integrityFailure();
                }
                outcome.requestsSeen = true;
                outcome.requests = value;
            } else {
                if (outcome.errorsSeen) {
                    throw integrityFailure();
                }
                outcome.errorsSeen = true;
                outcome.errors = value;
            }
        }
        Map<String, RequestOutcomeMeasurement> measurements = new LinkedHashMap<>();
        values.forEach((key, outcome) -> {
            Double requests = outcome.requestsSeen ? outcome.requests : null;
            Double errors = outcome.errorsSeen ? outcome.errors : null;
            if (requests != null && errors == null) {
                errors = 0d;
            }
            measurements.put(key, new RequestOutcomeMeasurement(requests, errors));
        });
        return new RequestOutcomeBatchMeasurement(measurements);
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

    private static void ensureSuccessForOutcomes(JsonNode root) {
        if (root == null || !"success".equals(root.path("status").asText())
                || !root.path("data").path("result").isArray()) {
            throw invalidOutcomes();
        }
    }

    private static RequestOutcomeQueryException invalidOutcomes() {
        return new RequestOutcomeQueryException(
                RequestOutcomeQueryException.Reason.INVALID_TELEMETRY,
                "Metrics backend returned invalid request outcome telemetry");
    }

    private static RequestOutcomeQueryException integrityFailure() {
        return new RequestOutcomeQueryException(
                RequestOutcomeQueryException.Reason.INTEGRITY,
                "Metrics backend returned an invalid bounded response");
    }

    private static final class MutableOutcome {
        private boolean requestsSeen;
        private boolean errorsSeen;
        private double requests;
        private double errors;
    }

    private static String text(JsonNode node, String field) {
        String value = node.path(field).asText(null);
        return value == null || value.isBlank() ? null : value;
    }
}
