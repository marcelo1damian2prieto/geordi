package io.geordi.logs.adapter.out.loki;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsBackendException;
import io.geordi.logs.application.port.out.LogsBackendProbe;
import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.net.SocketTimeoutException;
import java.time.Instant;
import java.util.List;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

public final class LokiLogsAdapter implements LogsQueryPort, LogsBackendProbe {

    private static final int PROBE_LIMIT = 1;

    private final RestClient client;
    private final ObjectMapper objectMapper;
    private final LokiQueryTranslator translator = new LokiQueryTranslator();
    private final LokiResponseParser parser = new LokiResponseParser();

    public LokiLogsAdapter(RestClient client, ObjectMapper objectMapper) {
        this.client = client;
        this.objectMapper = objectMapper;
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        return execute(() -> parser.services(series(translator.serviceDiscoveryQuery(), range)));
    }

    @Override
    public List<LogRecord> search(LogSearchCriteria criteria) {
        return execute(() -> parser.logs(
                queryRange(translator.searchQuery(criteria), criteria.range(), criteria.limit()), criteria));
    }

    @Override
    public boolean isQueryable() {
        Instant to = Instant.now();
        try {
            parser.validateStreams(queryRange(
                    translator.serviceDiscoveryQuery(), new TimeRange(to.minusSeconds(1), to), PROBE_LIMIT));
            return true;
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private JsonNode series(String query, TimeRange range) {
        String body = client.get().uri(builder -> builder.path("/loki/api/v1/series")
                        .queryParam("match[]", "{query}")
                        .queryParam("start", nanos(range.from()))
                        .queryParam("end", nanos(range.to()))
                        .build(query))
                .retrieve().body(String.class);
        return json(body);
    }

    private JsonNode queryRange(String query, TimeRange range, int limit) {
        String body = client.get().uri(builder -> builder.path("/loki/api/v1/query_range")
                        .queryParam("query", "{query}")
                        .queryParam("start", nanos(range.from()))
                        .queryParam("end", nanos(range.to()))
                        .queryParam("direction", "backward")
                        .queryParam("limit", limit)
                        .build(query))
                .retrieve().body(String.class);
        return json(body);
    }

    private JsonNode json(String body) {
        if (body == null || body.isBlank()) {
            throw new LogsBackendException(
                    LogsBackendException.Reason.MALFORMED_RESPONSE, "Loki returned an empty response");
        }
        try {
            return objectMapper.readTree(body);
        } catch (JsonProcessingException exception) {
            throw new LogsBackendException(
                    LogsBackendException.Reason.MALFORMED_RESPONSE, "Loki returned invalid JSON", exception);
        }
    }

    private static String nanos(Instant timestamp) {
        return java.math.BigInteger.valueOf(timestamp.getEpochSecond())
                .multiply(java.math.BigInteger.valueOf(1_000_000_000L))
                .add(java.math.BigInteger.valueOf(timestamp.getNano()))
                .toString();
    }

    private static <T> T execute(ResultSupplier<T> supplier) {
        try {
            return supplier.get();
        } catch (LogsBackendException exception) {
            throw exception;
        } catch (RestClientException exception) {
            throw classify(exception);
        }
    }

    private static LogsBackendException classify(RestClientException exception) {
        if (exception instanceof ResourceAccessException && hasTimeoutCause(exception)) {
            return new LogsBackendException(LogsBackendException.Reason.TIMEOUT, "Loki request timed out", exception);
        }
        if (exception instanceof RestClientResponseException response
                && (response.getStatusCode().value() == 408 || response.getStatusCode().value() == 504)) {
            return new LogsBackendException(LogsBackendException.Reason.TIMEOUT, "Loki request timed out", exception);
        }
        return new LogsBackendException(LogsBackendException.Reason.UNAVAILABLE, "Loki request failed", exception);
    }

    private static boolean hasTimeoutCause(Throwable throwable) {
        Throwable current = throwable;
        while (current != null) {
            if (current instanceof SocketTimeoutException) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }

    @FunctionalInterface
    private interface ResultSupplier<T> {
        T get();
    }
}
