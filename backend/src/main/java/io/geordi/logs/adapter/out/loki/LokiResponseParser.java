package io.geordi.logs.adapter.out.loki;

import com.fasterxml.jackson.databind.JsonNode;
import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsBackendException;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TraceId;
import java.math.BigInteger;
import java.time.DateTimeException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class LokiResponseParser {

    private static final String SERVICE_NAME = "service_name";
    private static final String SERVICE_NAMESPACE = "service_namespace";
    private static final String ENVIRONMENT = "deployment_environment_name";
    private static final String ORIGIN = "geordi_telemetry_origin";
    private static final Set<String> CANONICAL_FIELDS = Set.of(
            SERVICE_NAME, SERVICE_NAMESPACE, ENVIRONMENT, ORIGIN,
            "observed_timestamp", "severity_number", "severity_text", "trace_id", "span_id");
    private static final BigInteger BILLION = BigInteger.valueOf(1_000_000_000L);

    List<ServiceIdentity> services(JsonNode root) {
        ensureSuccess(root);
        JsonNode data = root.path("data");
        if (!data.isArray()) {
            throw malformed("Loki series response omitted data", null);
        }
        List<ServiceIdentity> services = new ArrayList<>();
        for (JsonNode series : data) {
            if (!series.isObject()) {
                throw malformed("Loki series response contained an invalid label set", null);
            }
            String name = text(series, SERVICE_NAME);
            String environment = text(series, ENVIRONMENT);
            if ("monitored".equals(text(series, ORIGIN)) && name != null && environment != null) {
                services.add(new ServiceIdentity(name, text(series, SERVICE_NAMESPACE), environment));
            }
        }
        return List.copyOf(services);
    }

    List<LogRecord> logs(JsonNode root, LogSearchCriteria criteria) {
        JsonNode result = streamResult(root);
        List<LogRecord> records = new ArrayList<>();
        for (JsonNode streamResult : result) {
            JsonNode stream = streamResult.path("stream");
            JsonNode values = streamResult.path("values");
            if (!stream.isObject() || !values.isArray()) {
                throw malformed("Loki returned an invalid stream", null);
            }
            Map<String, String> streamFields = stringMap(stream);
            for (JsonNode value : values) {
                records.add(log(value, streamFields, criteria));
            }
        }
        return List.copyOf(records);
    }

    void validateStreams(JsonNode root) {
        streamResult(root);
    }

    private static JsonNode streamResult(JsonNode root) {
        ensureSuccess(root);
        JsonNode data = root.path("data");
        if (!data.isObject() || !"streams".equals(data.path("resultType").asText())
                || !data.path("result").isArray()) {
            throw malformed("Loki response is not a log stream result", null);
        }
        return data.path("result");
    }

    private static LogRecord log(
            JsonNode value, Map<String, String> streamFields, LogSearchCriteria criteria) {
        if (!value.isArray() || value.size() < 2 || !value.get(0).isTextual() || !value.get(1).isTextual()) {
            throw malformed("Loki returned an invalid log entry", null);
        }
        Map<String, String> fields = new LinkedHashMap<>(streamFields);
        if (value.size() >= 3 && !value.get(2).isNull()) {
            if (!value.get(2).isObject()) {
                throw malformed("Loki returned invalid structured metadata", null);
            }
            stringMap(value.get(2)).forEach((key, item) -> merge(fields, key, item));
        }
        try {
            ServiceIdentity service = new ServiceIdentity(
                    required(fields, SERVICE_NAME), nullable(fields.get(SERVICE_NAMESPACE)), required(fields, ENVIRONMENT));
            if (!"monitored".equals(fields.get(ORIGIN)) || !criteria.service().equals(service)) {
                throw malformed("Loki log result did not prove the requested monitored identity", null);
            }
            Integer severityNumber = integer(fields.get("severity_number"));
            String severityText = nullable(fields.get("severity_text"));
            TraceId traceId = identifier(fields.get("trace_id"), true);
            SpanId spanId = spanIdentifier(fields.get("span_id"));
            Map<String, String> attributes = new LinkedHashMap<>(fields);
            CANONICAL_FIELDS.forEach(attributes::remove);
            return new LogRecord(
                    instant(value.get(0).asText()),
                    optionalInstant(fields.get("observed_timestamp")),
                    LogSeverity.from(severityNumber, severityText),
                    severityText,
                    value.get(1).asText(),
                    service,
                    traceId,
                    spanId,
                    attributes);
        } catch (IllegalArgumentException exception) {
            throw malformed("Loki returned invalid canonical log data", exception);
        }
    }

    private static void ensureSuccess(JsonNode root) {
        if (root == null || !root.isObject() || !"success".equals(root.path("status").asText())) {
            throw malformed("Loki returned an unsuccessful response", null);
        }
    }

    private static Map<String, String> stringMap(JsonNode object) {
        Map<String, String> values = new LinkedHashMap<>();
        var fields = object.fields();
        while (fields.hasNext()) {
            var field = fields.next();
            if (!field.getValue().isTextual()) {
                throw malformed("Loki metadata values must be strings", null);
            }
            values.put(field.getKey(), field.getValue().asText());
        }
        return values;
    }

    private static void merge(Map<String, String> target, String key, String value) {
        String existing = target.putIfAbsent(key, value);
        if (existing != null && !existing.equals(value)) {
            throw malformed("Loki returned conflicting metadata", null);
        }
    }

    private static Instant instant(String value) {
        try {
            if (value.matches("-?[0-9]+")) {
                BigInteger[] parts = new BigInteger(value).divideAndRemainder(BILLION);
                return Instant.ofEpochSecond(parts[0].longValueExact(), parts[1].longValueExact());
            }
            return Instant.parse(value);
        } catch (ArithmeticException | DateTimeException exception) {
            throw new IllegalArgumentException("timestamp is invalid", exception);
        }
    }

    private static Instant optionalInstant(String value) {
        return value == null || value.isBlank() ? null : instant(value);
    }

    private static Integer integer(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return Integer.valueOf(value);
    }

    private static TraceId identifier(String value, boolean trace) {
        if (value == null || value.isBlank()) {
            return null;
        }
        if (!trace) {
            throw new IllegalArgumentException("unexpected identifier type");
        }
        return new TraceId(value);
    }

    private static SpanId spanIdentifier(String value) {
        return value == null || value.isBlank() ? null : new SpanId(value);
    }

    private static String required(Map<String, String> fields, String key) {
        String value = nullable(fields.get(key));
        if (value == null) {
            throw new IllegalArgumentException(key + " must not be blank");
        }
        return value;
    }

    private static String text(JsonNode node, String field) {
        return nullable(node.path(field).asText(null));
    }

    private static String nullable(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static LogsBackendException malformed(String message, Throwable cause) {
        return new LogsBackendException(LogsBackendException.Reason.MALFORMED_RESPONSE, message, cause);
    }
}
