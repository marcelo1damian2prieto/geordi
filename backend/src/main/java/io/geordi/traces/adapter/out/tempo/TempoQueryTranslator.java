package io.geordi.traces.adapter.out.tempo;

import io.geordi.traces.application.TraceSearchCriteria;

final class TempoQueryTranslator {

    private static final String SELECT_IDENTITY = " | select(resource.service.name, "
            + "resource.service.namespace, resource.deployment.environment.name, "
            + "resource.geordi.telemetry.origin)";

    String serviceDiscoveryQuery() {
        return "{ resource.geordi.telemetry.origin = \"monitored\""
                + " && resource.service.name != nil"
                + " && resource.deployment.environment.name != nil }"
                + SELECT_IDENTITY;
    }

    String searchQuery(TraceSearchCriteria criteria) {
        StringBuilder query = new StringBuilder("{ resource.geordi.telemetry.origin = \"monitored\"")
                .append(" && resource.service.name = \"").append(escape(criteria.service().name())).append('"')
                .append(" && resource.deployment.environment.name = \"")
                .append(escape(criteria.service().environment())).append('"');
        if (criteria.service().namespace() == null) {
            query.append(" && resource.service.namespace = nil");
        } else {
            query.append(" && resource.service.namespace = \"")
                    .append(escape(criteria.service().namespace())).append('"');
        }
        if (criteria.errorOnly()) {
            query.append(" && status = error");
        }
        return query.append(" }").append(SELECT_IDENTITY).toString();
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t");
    }
}
