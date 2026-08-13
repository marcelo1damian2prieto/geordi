package io.geordi.traces.adapter.out.tempo;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.port.out.TraceBackendProbe;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.net.SocketTimeoutException;
import java.util.List;
import java.util.Optional;
import org.springframework.http.HttpStatus;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

public final class TempoTraceAdapter implements TraceQueryPort, TraceBackendProbe {

    private static final int DISCOVERY_LIMIT = 50;
    private static final int SPANS_PER_SPAN_SET = 1;

    private final RestClient client;
    private final ObjectMapper objectMapper;
    private final TempoQueryTranslator translator = new TempoQueryTranslator();
    private final TempoResponseParser parser = new TempoResponseParser();

    public TempoTraceAdapter(RestClient client, ObjectMapper objectMapper) {
        this.client = client;
        this.objectMapper = objectMapper;
    }

    @Override
    public List<ServiceIdentity> findServices(TimeRange range) {
        return execute(() -> parser.services(search(translator.serviceDiscoveryQuery(), range, DISCOVERY_LIMIT), range));
    }

    @Override
    public List<TraceSummary> search(TraceSearchCriteria criteria) {
        return execute(() -> parser.summaries(
                search(translator.searchQuery(criteria), criteria.range(), criteria.limit()), criteria));
    }

    @Override
    public Optional<TraceDetail> findTrace(TraceId traceId) {
        try {
            String body = client.get().uri("/api/v2/traces/{traceId}", traceId.value())
                    .retrieve().body(String.class);
            return Optional.of(parser.detail(json(body), traceId));
        } catch (RestClientResponseException exception) {
            if (exception.getStatusCode() == HttpStatus.NOT_FOUND) {
                return Optional.empty();
            }
            throw classify(exception);
        } catch (TraceBackendException exception) {
            throw exception;
        } catch (RestClientException exception) {
            throw classify(exception);
        }
    }

    @Override
    public boolean isQueryable() {
        try {
            String body = client.get().uri("/api/echo").retrieve().body(String.class);
            return body != null && "echo".equals(body.trim());
        } catch (RestClientException exception) {
            return false;
        }
    }

    private JsonNode search(String query, TimeRange range, int limit) {
        String body = client.get().uri(builder -> builder.path("/api/search")
                        .queryParam("q", "{query}")
                        .queryParam("start", range.from().getEpochSecond())
                        .queryParam("end", upperBoundEpochSecond(range.to()))
                        .queryParam("limit", limit)
                        .queryParam("spss", SPANS_PER_SPAN_SET)
                        .build(query))
                .retrieve().body(String.class);
        return json(body);
    }

    private static long upperBoundEpochSecond(java.time.Instant exclusiveTo) {
        return exclusiveTo.getEpochSecond() + (exclusiveTo.getNano() == 0 ? 0 : 1);
    }

    private JsonNode json(String body) {
        if (body == null || body.isBlank()) {
            throw new TraceBackendException(
                    TraceBackendException.Reason.MALFORMED_RESPONSE, "Tempo returned an empty response");
        }
        try {
            return objectMapper.readTree(body);
        } catch (JsonProcessingException exception) {
            throw new TraceBackendException(
                    TraceBackendException.Reason.MALFORMED_RESPONSE, "Tempo returned invalid JSON", exception);
        }
    }

    private static <T> T execute(SupplierWithResult<T> supplier) {
        try {
            return supplier.get();
        } catch (TraceBackendException exception) {
            throw exception;
        } catch (RestClientException exception) {
            throw classify(exception);
        }
    }

    private static TraceBackendException classify(RestClientException exception) {
        if (exception instanceof ResourceAccessException && hasTimeoutCause(exception)) {
            return new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT, "Tempo request timed out", exception);
        }
        if (exception instanceof RestClientResponseException response
                && (response.getStatusCode().value() == 408 || response.getStatusCode().value() == 504)) {
            return new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT, "Tempo request timed out", exception);
        }
        return new TraceBackendException(
                TraceBackendException.Reason.UNAVAILABLE, "Tempo request failed", exception);
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
    private interface SupplierWithResult<T> {
        T get();
    }
}
