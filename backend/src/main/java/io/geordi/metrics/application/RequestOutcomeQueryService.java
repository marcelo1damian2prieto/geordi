package io.geordi.metrics.application;

import io.geordi.metrics.application.port.out.RequestOutcomeQueryPort;
import io.geordi.metrics.application.port.out.RequestOutcomeBatchQueryPort;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Duration;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

public final class RequestOutcomeQueryService implements AutoCloseable {

    private static final Duration DEFAULT_BATCH_DEADLINE = Duration.ofSeconds(5);

    private final RequestOutcomeQueryPort port;
    private final RequestOutcomeBatchQueryPort batchPort;
    private final Duration batchDeadline;
    private final ExecutorService batchExecutor;

    public RequestOutcomeQueryService(RequestOutcomeQueryPort port) {
        this(port, query -> {
            throw new RequestOutcomeQueryException(
                    RequestOutcomeQueryException.Reason.UNAVAILABLE,
                    "Bounded request outcome query is unavailable");
        });
    }

    public RequestOutcomeQueryService(RequestOutcomeQueryPort port, RequestOutcomeBatchQueryPort batchPort) {
        this(port, batchPort, DEFAULT_BATCH_DEADLINE);
    }

    public RequestOutcomeQueryService(
            RequestOutcomeQueryPort port, RequestOutcomeBatchQueryPort batchPort, Duration batchDeadline) {
        this.port = Objects.requireNonNull(port, "request outcome query port must not be null");
        this.batchPort = Objects.requireNonNull(batchPort, "request outcome batch query port must not be null");
        this.batchDeadline = requirePositive(batchDeadline);
        this.batchExecutor = Executors.newThreadPerTaskExecutor(
                Thread.ofVirtual().name("geordi-metrics-bounded-", 0).factory());
    }

    public RequestOutcomeMeasurement measure(ServiceIdentity service, TimeRange range) {
        return port.query(new RequestOutcomeQuery(service, range));
    }

    public RequestOutcomeBatchMeasurement measureBatch(RequestOutcomeBatchQuery query) {
        RequestOutcomeBatchQuery requiredQuery =
                Objects.requireNonNull(query, "request outcome batch query must not be null");
        Future<RequestOutcomeBatchMeasurement> operation = batchExecutor.submit(() -> batchPort.queryBatch(requiredQuery));
        try {
            return operation.get(batchDeadline.toNanos(), TimeUnit.NANOSECONDS);
        } catch (TimeoutException exception) {
            operation.cancel(true);
            throw unavailable("Bounded request outcome query deadline expired", exception);
        } catch (InterruptedException exception) {
            operation.cancel(true);
            Thread.currentThread().interrupt();
            throw unavailable("Bounded request outcome query was interrupted", exception);
        } catch (ExecutionException exception) {
            throw propagate(exception.getCause());
        }
    }

    @Override
    public void close() {
        batchExecutor.shutdownNow();
    }

    private static Duration requirePositive(Duration deadline) {
        Objects.requireNonNull(deadline, "request outcome batch deadline must not be null");
        if (deadline.isZero() || deadline.isNegative()) {
            throw new IllegalArgumentException("request outcome batch deadline must be positive");
        }
        return deadline;
    }

    private static RequestOutcomeQueryException unavailable(String message, Exception cause) {
        return new RequestOutcomeQueryException(RequestOutcomeQueryException.Reason.UNAVAILABLE, message, cause);
    }

    private static RuntimeException propagate(Throwable cause) {
        if (cause instanceof RuntimeException runtimeException) {
            return runtimeException;
        }
        if (cause instanceof Error error) {
            throw error;
        }
        return unavailable("Bounded request outcome query failed", new IllegalStateException(cause));
    }
}
