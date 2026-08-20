package io.geordi.traces.adapter.out.tempo;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.application.TraceDependencyQuery;
import io.geordi.traces.application.port.out.TraceBackendProbe;
import io.geordi.traces.application.port.out.TraceDependencyQueryPort;
import io.geordi.traces.application.port.out.TraceQueryPort;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import io.geordi.traces.domain.TraceCandidateBatch;
import java.net.SocketTimeoutException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.springframework.http.HttpStatus;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

public final class TempoTraceAdapter implements TraceQueryPort, TraceBackendProbe,
        TraceDependencyQueryPort, AutoCloseable {

    private static final int DISCOVERY_LIMIT = 50;
    private static final int SERVICE_MAP_CANDIDATE_FETCH_LIMIT = 51;
    private static final int SERVICE_MAP_DETAIL_LIMIT = 50;
    private static final int SERVICE_MAP_CONCURRENCY = 8;
    private static final int SERVICE_MAP_QUEUE_CAPACITY = 50;
    private static final int SPANS_PER_SPAN_SET = 1;
    private static final Duration SERVICE_MAP_BUDGET = Duration.ofSeconds(10);

    private final RestClient client;
    private final ObjectMapper objectMapper;
    private final TempoQueryTranslator translator = new TempoQueryTranslator();
    private final TempoResponseParser parser = new TempoResponseParser();
    private final ThreadPoolExecutor detailExecutor;
    private final Duration serviceMapBudget;

    public TempoTraceAdapter(RestClient client, ObjectMapper objectMapper) {
        this(client, objectMapper, boundedDetailExecutor());
    }

    TempoTraceAdapter(RestClient client, ObjectMapper objectMapper, ThreadPoolExecutor detailExecutor) {
        this(client, objectMapper, detailExecutor, SERVICE_MAP_BUDGET);
    }

    TempoTraceAdapter(
            RestClient client,
            ObjectMapper objectMapper,
            ThreadPoolExecutor detailExecutor,
            Duration serviceMapBudget) {
        this.client = client;
        this.objectMapper = objectMapper;
        this.detailExecutor = detailExecutor;
        if (serviceMapBudget == null || serviceMapBudget.isZero() || serviceMapBudget.isNegative()) {
            throw new IllegalArgumentException("service map budget must be positive");
        }
        this.serviceMapBudget = serviceMapBudget;
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

    @Override
    public TraceCandidateBatch findDependencyCandidates(TraceDependencyQuery query) {
        long deadline = System.nanoTime() + serviceMapBudget.toNanos();
        try {
            TimeRange range = new TimeRange(
                    query.range().from(), query.range().to());
            List<TraceId> identifiers = fetchCandidateIdentifiers(query, range, deadline);
            boolean truncated = identifiers.size() > SERVICE_MAP_DETAIL_LIMIT;
            List<TraceId> selected = identifiers.stream().limit(SERVICE_MAP_DETAIL_LIMIT).toList();
            return new TraceCandidateBatch(
                    fetchCandidateDetails(selected, deadline), truncated);
        } catch (TraceBackendException exception) {
            throw exception;
        } catch (RestClientException exception) {
            throw classify(exception);
        }
    }

    @Override
    public void close() {
        detailExecutor.shutdownNow();
    }

    private List<TraceDetail> fetchCandidateDetails(
            List<TraceId> traceIds, long deadline) {
        List<Future<TraceDetail>> futures = new ArrayList<>(traceIds.size());
        try {
            for (TraceId traceId : traceIds) {
                futures.add(detailExecutor.submit(() -> candidateTrace(traceId)));
            }
        } catch (RejectedExecutionException exception) {
            cancel(futures);
            throw new TraceBackendException(
                    TraceBackendException.Reason.UNAVAILABLE,
                    "Trace storage detail capacity is exhausted",
                    exception);
        }
        List<TraceDetail> traces = new ArrayList<>(traceIds.size());
        try {
            for (Future<TraceDetail> future : futures) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) {
                    throw new TimeoutException("service map budget exhausted");
                }
                traces.add(future.get(remaining, TimeUnit.NANOSECONDS));
            }
            return List.copyOf(traces);
        } catch (TimeoutException exception) {
            cancel(futures);
            throw new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT,
                    "Trace storage exceeded the service map query budget",
                    exception);
        } catch (InterruptedException exception) {
            cancel(futures);
            Thread.currentThread().interrupt();
            throw new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT,
                    "Service map trace retrieval was interrupted",
                    exception);
        } catch (ExecutionException exception) {
            cancel(futures);
            Throwable cause = exception.getCause();
            if (cause instanceof TraceBackendException failure) {
                throw failure;
            }
            throw new TraceBackendException(
                    TraceBackendException.Reason.UNAVAILABLE,
                    "Trace storage detail retrieval failed",
                    cause);
        }
    }

    private List<TraceId> fetchCandidateIdentifiers(
            TraceDependencyQuery query, TimeRange range, long deadline) {
        Future<List<TraceId>> future;
        try {
            future = detailExecutor.submit(() -> execute(() -> parser.candidateTraceIds(search(
                    translator.dependencyCandidatesQuery(query.environment()),
                    range,
                    SERVICE_MAP_CANDIDATE_FETCH_LIMIT))));
        } catch (RejectedExecutionException exception) {
            throw new TraceBackendException(
                    TraceBackendException.Reason.UNAVAILABLE,
                    "Trace storage candidate capacity is exhausted",
                    exception);
        }
        try {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) {
                throw new TimeoutException("service map budget exhausted");
            }
            return future.get(remaining, TimeUnit.NANOSECONDS);
        } catch (TimeoutException exception) {
            cancel(List.of(future));
            throw new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT,
                    "Trace storage exceeded the service map query budget",
                    exception);
        } catch (InterruptedException exception) {
            cancel(List.of(future));
            Thread.currentThread().interrupt();
            throw new TraceBackendException(
                    TraceBackendException.Reason.TIMEOUT,
                    "Service map candidate retrieval was interrupted",
                    exception);
        } catch (ExecutionException exception) {
            Throwable cause = exception.getCause();
            if (cause instanceof TraceBackendException failure) {
                throw failure;
            }
            throw new TraceBackendException(
                    TraceBackendException.Reason.UNAVAILABLE,
                    "Trace storage candidate retrieval failed",
                    cause);
        }
    }

    private TraceDetail candidateTrace(TraceId traceId) {
        return findTrace(traceId).orElseThrow(() -> new TraceBackendException(
                TraceBackendException.Reason.MALFORMED_RESPONSE,
                "A candidate trace disappeared before detail retrieval"));
    }

    private void cancel(List<? extends Future<?>> futures) {
        futures.forEach(future -> future.cancel(true));
        detailExecutor.purge();
    }

    private static ThreadFactory daemonThreadFactory() {
        return runnable -> {
            Thread thread = new Thread(runnable, "geordi-service-map-detail");
            thread.setDaemon(true);
            return thread;
        };
    }

    private static ThreadPoolExecutor boundedDetailExecutor() {
        return new ThreadPoolExecutor(
                SERVICE_MAP_CONCURRENCY,
                SERVICE_MAP_CONCURRENCY,
                0,
                TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(SERVICE_MAP_QUEUE_CAPACITY),
                daemonThreadFactory(),
                new ThreadPoolExecutor.AbortPolicy());
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
