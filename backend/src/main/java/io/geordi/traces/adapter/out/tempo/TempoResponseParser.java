package io.geordi.traces.adapter.out.tempo;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.domain.HttpMetadata;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.SpanId;
import io.geordi.traces.domain.SpanKind;
import io.geordi.traces.domain.SpanService;
import io.geordi.traces.domain.SpanStatus;
import io.geordi.traces.domain.TelemetryOrigin;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSpan;
import io.geordi.traces.domain.TraceSummary;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class TempoResponseParser {

    private static final String SERVICE_NAME = "service.name";
    private static final String SERVICE_NAMESPACE = "service.namespace";
    private static final String ENVIRONMENT = "deployment.environment.name";
    private static final String TELEMETRY_ORIGIN = "geordi.telemetry.origin";

    List<ServiceIdentity> services(JsonNode root, TimeRange range) {
        requireObject(root);
        List<ServiceIdentity> services = new ArrayList<>();
        for (JsonNode trace : requiredArray(root, "traces")) {
            for (JsonNode span : matchingSpans(trace)) {
                Instant start = instant(span, "startTimeUnixNano");
                Map<String, JsonNode> attributes = attributes(span.path("attributes"));
                if (range.contains(start) && "monitored".equals(stringValue(attributes.get(TELEMETRY_ORIGIN)))) {
                    String name = stringValue(attributes.get(SERVICE_NAME));
                    String environment = stringValue(attributes.get(ENVIRONMENT));
                    if (hasText(name) && hasText(environment)) {
                        services.add(new ServiceIdentity(
                                name, stringValue(attributes.get(SERVICE_NAMESPACE)), environment));
                    }
                }
            }
        }
        return List.copyOf(services);
    }

    List<TraceSummary> summaries(JsonNode root, TraceSearchCriteria criteria) {
        requireObject(root);
        List<TraceSummary> summaries = new ArrayList<>();
        for (JsonNode trace : requiredArray(root, "traces")) {
            if (!hasMatchingIdentity(trace, criteria.service())) {
                throw malformed("Tempo search result did not prove the requested service identity", null);
            }
            int spanCount = 0;
            int errorCount = 0;
            JsonNode stats = trace.path("serviceStats");
            if (!stats.isObject()) {
                throw malformed("Tempo search response omitted service statistics", null);
            }
            var fields = stats.fields();
            while (fields.hasNext()) {
                JsonNode value = fields.next().getValue();
                spanCount = Math.addExact(spanCount, requiredInt(value, "spanCount"));
                errorCount = Math.addExact(errorCount, optionalInt(value, "errorCount", 0));
            }
            try {
                summaries.add(new TraceSummary(
                        searchTraceId(trace),
                        optionalText(trace, "rootServiceName"),
                        requiredText(trace, "rootTraceName"),
                        instant(trace, "startTimeUnixNano"),
                        Duration.ofMillis(optionalLong(trace, "durationMs", 0)),
                        spanCount,
                        errorCount > 0));
            } catch (IllegalArgumentException | ArithmeticException exception) {
                throw malformed("Tempo returned invalid trace summary values", exception);
            }
        }
        return List.copyOf(summaries);
    }

    List<TraceId> candidateTraceIds(JsonNode root) {
        requireObject(root);
        LinkedHashSet<TraceId> identifiers = new LinkedHashSet<>();
        for (JsonNode trace : requiredArray(root, "traces")) {
            identifiers.add(searchTraceId(trace));
        }
        return List.copyOf(identifiers);
    }

    TraceDetail detail(JsonNode root, TraceId requestedTraceId) {
        requireObject(root);
        String status = optionalText(root, "status");
        if (status != null && !"COMPLETE".equals(status) && !"0".equals(status)) {
            throw malformed("Tempo returned a partial trace", null);
        }
        JsonNode trace = root.path("trace");
        if (!trace.isObject()) {
            throw malformed("Tempo trace response is missing trace data", null);
        }
        List<TraceSpan> spans = new ArrayList<>();
        for (JsonNode resourceSpans : requiredArray(trace, "resourceSpans")) {
            Map<String, JsonNode> resourceAttributes = attributes(
                    resourceSpans.path("resource").path("attributes"));
            SpanService service = spanService(resourceAttributes);
            for (JsonNode scopeSpans : requiredArray(resourceSpans, "scopeSpans")) {
                for (JsonNode span : requiredArray(scopeSpans, "spans")) {
                    spans.add(span(span, service, requestedTraceId));
                }
            }
        }
        try {
            return new TraceDetail(requestedTraceId, spans);
        } catch (IllegalArgumentException | ArithmeticException exception) {
            throw malformed("Tempo returned an invalid span hierarchy", exception);
        }
    }

    private TraceSpan span(JsonNode node, SpanService service, TraceId requestedTraceId) {
        try {
            TraceId traceId = new TraceId(identifier(node, "traceId", 16));
            if (!requestedTraceId.equals(traceId)) {
                throw new IllegalArgumentException("span trace id does not match the requested trace");
            }
            SpanId spanId = new SpanId(identifier(node, "spanId", 8));
            SpanId parentId = optionalIdentifier(node, "parentSpanId", 8);
            Instant start = instant(node, "startTimeUnixNano");
            Instant end = instant(node, "endTimeUnixNano");
            Duration duration = Duration.between(start, end);
            Map<String, JsonNode> spanAttributes = attributes(node.path("attributes"));
            return new TraceSpan(
                    traceId,
                    spanId,
                    parentId,
                    requiredText(node, "name"),
                    service,
                    spanKind(node.path("kind")),
                    spanStatus(node.path("status").path("code")),
                    start,
                    duration,
                    stringValue(spanAttributes.get("error.type")),
                    httpMetadata(spanAttributes));
        } catch (IllegalArgumentException | ArithmeticException exception) {
            throw malformed("Tempo returned invalid span data", exception);
        }
    }

    private static boolean hasMatchingIdentity(JsonNode trace, ServiceIdentity expected) {
        for (JsonNode span : matchingSpans(trace)) {
            Map<String, JsonNode> attributes = attributes(span.path("attributes"));
            String actualNamespace = stringValue(attributes.get(SERVICE_NAMESPACE));
            if ("monitored".equals(stringValue(attributes.get(TELEMETRY_ORIGIN)))
                    && expected.name().equals(stringValue(attributes.get(SERVICE_NAME)))
                    && expected.environment().equals(stringValue(attributes.get(ENVIRONMENT)))
                    && java.util.Objects.equals(expected.namespace(), normalize(actualNamespace))) {
                return true;
            }
        }
        return false;
    }

    private static List<JsonNode> matchingSpans(JsonNode trace) {
        List<JsonNode> spans = new ArrayList<>();
        JsonNode spanSets = trace.path("spanSets");
        if (spanSets.isArray()) {
            for (JsonNode spanSet : spanSets) {
                spanSet.path("spans").forEach(spans::add);
            }
        }
        JsonNode legacy = trace.path("spanSet").path("spans");
        if (legacy.isArray()) {
            legacy.forEach(spans::add);
        }
        return List.copyOf(spans);
    }

    private static SpanService spanService(Map<String, JsonNode> attributes) {
        return new SpanService(
                stringValue(attributes.get(SERVICE_NAME)),
                stringValue(attributes.get(SERVICE_NAMESPACE)),
                stringValue(attributes.get(ENVIRONMENT)),
                telemetryOrigin(stringValue(attributes.get(TELEMETRY_ORIGIN))));
    }

    private static TelemetryOrigin telemetryOrigin(String value) {
        if ("monitored".equals(value)) {
            return TelemetryOrigin.MONITORED;
        }
        if ("platform".equals(value)) {
            return TelemetryOrigin.PLATFORM;
        }
        return TelemetryOrigin.UNCLASSIFIED;
    }

    private static SpanKind spanKind(JsonNode value) {
        if (value.isInt() || value.isLong()) {
            return switch (value.asInt()) {
                case 0 -> SpanKind.UNSPECIFIED;
                case 1 -> SpanKind.INTERNAL;
                case 2 -> SpanKind.SERVER;
                case 3 -> SpanKind.CLIENT;
                case 4 -> SpanKind.PRODUCER;
                case 5 -> SpanKind.CONSUMER;
                default -> throw new IllegalArgumentException("unsupported span kind");
            };
        }
        String name = value.asText("");
        if (name.startsWith("SPAN_KIND_")) {
            name = name.substring("SPAN_KIND_".length());
        }
        return SpanKind.valueOf(name.toUpperCase(Locale.ROOT));
    }

    private static SpanStatus spanStatus(JsonNode value) {
        if (value.isMissingNode() || value.isNull() || "".equals(value.asText())) {
            return SpanStatus.UNSET;
        }
        if (value.isInt() || value.isLong()) {
            return switch (value.asInt()) {
                case 0 -> SpanStatus.UNSET;
                case 1 -> SpanStatus.OK;
                case 2 -> SpanStatus.ERROR;
                default -> throw new IllegalArgumentException("unsupported span status");
            };
        }
        String name = value.asText();
        if (name.startsWith("STATUS_CODE_")) {
            name = name.substring("STATUS_CODE_".length());
        }
        return SpanStatus.valueOf(name.toUpperCase(Locale.ROOT));
    }

    private static HttpMetadata httpMetadata(Map<String, JsonNode> attributes) {
        Integer responseStatus = integerValue(attributes.get("http.response.status_code"));
        Integer serverPort = integerValue(attributes.get("server.port"));
        HttpMetadata metadata = new HttpMetadata(
                stringValue(attributes.get("http.request.method")),
                stringValue(attributes.get("http.route")),
                stringValue(attributes.get("url.path")),
                responseStatus,
                stringValue(attributes.get("server.address")),
                serverPort);
        return metadata.isEmpty() ? null : metadata;
    }

    private static Map<String, JsonNode> attributes(JsonNode array) {
        if (array.isMissingNode() || array.isNull()) {
            return Map.of();
        }
        if (!array.isArray()) {
            throw malformed("Tempo attributes are not an array", null);
        }
        Map<String, JsonNode> attributes = new LinkedHashMap<>();
        for (JsonNode attribute : array) {
            String key = requiredText(attribute, "key");
            JsonNode previous = attributes.putIfAbsent(key, attribute.path("value"));
            if (previous != null) {
                throw malformed("Tempo returned duplicate attributes", null);
            }
        }
        return Map.copyOf(attributes);
    }

    private static String stringValue(JsonNode value) {
        if (value == null || value.isMissingNode() || value.isNull()) {
            return null;
        }
        JsonNode string = value.path("stringValue");
        return string.isTextual() ? normalize(string.asText()) : null;
    }

    private static Integer integerValue(JsonNode value) {
        if (value == null || value.isMissingNode() || value.isNull()) {
            return null;
        }
        JsonNode integer = value.path("intValue");
        if (!integer.isIntegralNumber() && !integer.isTextual()) {
            return null;
        }
        return Math.toIntExact(integer.asLong());
    }

    private static String identifier(JsonNode node, String field, int expectedBytes) {
        String value = requiredText(node, field);
        int hexLength = expectedBytes * 2;
        if (value.matches("[0-9a-fA-F]{" + hexLength + "}")) {
            return value;
        }
        byte[] decoded = Base64.getDecoder().decode(value);
        if (decoded.length != expectedBytes) {
            throw new IllegalArgumentException("identifier has the wrong byte length");
        }
        return java.util.HexFormat.of().formatHex(decoded);
    }

    private static SpanId optionalIdentifier(JsonNode node, String field, int expectedBytes) {
        String value = optionalText(node, field);
        return value == null ? null : new SpanId(identifier(node, field, expectedBytes));
    }

    private static TraceId searchTraceId(JsonNode trace) {
        String value = requiredText(trace, "traceID");
        if (!value.matches("[0-9a-fA-F]{1,32}")) {
            throw malformed("Tempo returned an invalid search trace id", null);
        }
        return new TraceId("0".repeat(32 - value.length()) + value);
    }

    private static Instant instant(JsonNode node, String field) {
        long nanos = requiredLong(node, field);
        if (nanos < 0) {
            throw new IllegalArgumentException("timestamp must not be negative");
        }
        return Instant.ofEpochSecond(nanos / 1_000_000_000, nanos % 1_000_000_000);
    }

    private static long requiredLong(JsonNode node, String field) {
        JsonNode value = node.path(field);
        if ((!value.isIntegralNumber() && !value.isTextual()) || value.asText().isBlank()) {
            throw malformed("Tempo response omitted numeric field " + field, null);
        }
        try {
            return value.isTextual() ? Long.parseLong(value.textValue()) : value.longValue();
        } catch (NumberFormatException exception) {
            throw malformed("Tempo returned invalid numeric field " + field, exception);
        }
    }

    private static int requiredInt(JsonNode node, String field) {
        return Math.toIntExact(requiredLong(node, field));
    }

    private static long optionalLong(JsonNode node, String field, long defaultValue) {
        return node.path(field).isMissingNode() ? defaultValue : requiredLong(node, field);
    }

    private static int optionalInt(JsonNode node, String field, int defaultValue) {
        return node.path(field).isMissingNode() ? defaultValue : requiredInt(node, field);
    }

    private static String requiredText(JsonNode node, String field) {
        String value = optionalText(node, field);
        if (value == null) {
            throw malformed("Tempo response omitted field " + field, null);
        }
        return value;
    }

    private static String optionalText(JsonNode node, String field) {
        JsonNode value = node.path(field);
        return value.isTextual() ? normalize(value.asText()) : null;
    }

    private static JsonNode requiredArray(JsonNode node, String field) {
        JsonNode value = node.path(field);
        if (!value.isArray()) {
            throw malformed("Tempo response omitted array " + field, null);
        }
        return value;
    }

    private static void requireObject(JsonNode root) {
        if (root == null || !root.isObject()) {
            throw malformed("Tempo returned an invalid JSON envelope", null);
        }
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private static boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    private static TraceBackendException malformed(String message, Throwable cause) {
        return new TraceBackendException(TraceBackendException.Reason.MALFORMED_RESPONSE, message, cause);
    }
}
