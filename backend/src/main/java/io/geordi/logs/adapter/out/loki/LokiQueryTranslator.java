package io.geordi.logs.adapter.out.loki;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.domain.LogSeverity;

final class LokiQueryTranslator {

    String serviceDiscoveryQuery() {
        return "{geordi_telemetry_origin=\"monitored\",service_name=~\".+\","
                + "deployment_environment_name=~\".+\"}";
    }

    String searchQuery(LogSearchCriteria criteria) {
        StringBuilder query = new StringBuilder("{geordi_telemetry_origin=\"monitored\"")
                .append(",service_name=\"").append(escape(criteria.service().name())).append('"')
                .append(",deployment_environment_name=\"")
                .append(escape(criteria.service().environment())).append('"')
                .append(",service_namespace=\"")
                .append(escape(criteria.service().namespace() == null ? "" : criteria.service().namespace()))
                .append("\"}");
        appendSeverity(query, criteria.severity());
        if (criteria.text() != null) {
            query.append(" |= \"").append(escape(criteria.text())).append('"');
        }
        if (criteria.traceId() != null) {
            query.append(" | trace_id=\"").append(criteria.traceId().value()).append('"');
        }
        if (criteria.spanId() != null) {
            query.append(" | span_id=\"").append(criteria.spanId().value()).append('"');
        }
        return query.toString();
    }

    private static void appendSeverity(StringBuilder query, LogSeverity severity) {
        if (severity == null) {
            return;
        }
        if (severity == LogSeverity.UNSPECIFIED) {
            query.append(" | severity_number=\"0\"");
            return;
        }
        int lower = (severity.ordinal() - 1) * 4 + 1;
        int upper = lower + 3;
        query.append(" | severity_number >= ").append(lower)
                .append(" and severity_number <= ").append(upper)
                .append(" | __error__=\"\"");
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}
