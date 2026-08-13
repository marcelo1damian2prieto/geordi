package io.geordi.metrics.adapter.out.victoriametrics;

import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.domain.OperationalMetric;
import java.time.Duration;

final class VictoriaMetricsQueryTranslator {

    String translate(MetricsQuery query, OperationalMetric metric) {
        String selectors = selectors(query);
        long rollupWindow = Math.max(10, query.resolution().toSeconds());
        long fullRange = Duration.between(query.range().from(), query.range().to()).toSeconds();
        return switch (metric) {
            case JVM_MEMORY_USED -> "sum(" + vector("jvm.memory.used", selectors) + ")";
            case JVM_CPU_UTILIZATION -> "avg(" + vector("jvm.cpu.recent_utilization", selectors) + ")";
            case JVM_THREAD_COUNT -> "sum(" + vector("jvm.thread.count", selectors) + ")";
            case JVM_GC_DURATION -> "sum(increase(" + vector("jvm.gc.duration_sum", selectors)
                    + "[" + rollupWindow + "s]))";
            case HTTP_REQUEST_RATE -> "sum(rate(" + vector("http.server.request.duration_count", selectors)
                    + "[" + rollupWindow + "s]))";
            case HTTP_REQUEST_COUNT -> "sum(increase(" + vector("http.server.request.duration_count", selectors) + "["
                    + fullRange + "s]))";
            case HTTP_REQUEST_LATENCY_P95 -> "histogram_quantile(0.95,sum(rate("
                    + vector("http.server.request.duration_bucket", selectors)
                    + "[" + rollupWindow + "s])) by (le))";
            case HTTP_ERROR_RATE -> errorRate(selectors, rollupWindow);
            case HTTP_ERROR_COUNT -> "sum(increase(" + vector("http.server.request.duration_count",
                    selectors + ",\"http.response.status_code\"=~\"5..\"") + "[" + fullRange + "s]))";
        };
    }

    private static String errorRate(String selectors, long step) {
        String all = "sum(rate(" + vector("http.server.request.duration_count", selectors)
                + "[" + step + "s]))";
        String errors = "sum(rate(" + vector("http.server.request.duration_count",
                selectors + ",\"http.response.status_code\"=~\"5..\"") + "[" + step + "s]))";
        return errors + " / " + all;
    }

    private static String vector(String metricName, String selectors) {
        return "{__name__=\"" + metricName + "\"," + selectors + "}";
    }

    private static String selectors(MetricsQuery query) {
        StringBuilder value = new StringBuilder("\"geordi.telemetry.origin\"=\"monitored\"")
                .append(",\"service.name\"=\"").append(escape(query.service().name())).append('"')
                .append(",\"deployment.environment.name\"=\"")
                .append(escape(query.service().environment())).append('"');
        value.append(",\"service.namespace\"=\"")
                .append(escape(query.service().namespace() == null ? "" : query.service().namespace()))
                .append('"');
        return value.toString();
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }
}
