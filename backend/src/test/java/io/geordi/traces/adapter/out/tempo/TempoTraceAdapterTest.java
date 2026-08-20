package io.geordi.traces.adapter.out.tempo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withResourceNotFound;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceDependencyQuery;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceId;
import java.time.Instant;
import java.time.Duration;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

class TempoTraceAdapterTest {

    private static final TraceId TRACE_ID = new TraceId("0123456789abcdef0123456789abcdef");

    @Test
    void probeRequiresTheQueryEchoContract() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(requestTo("http://tempo.test/api/echo"))
                .andRespond(withSuccess("echo\n", MediaType.TEXT_PLAIN));

        assertThat(adapter(builder).isQueryable()).isTrue();
        server.verify();
    }

    @Test
    void mapsDetailNotFoundWithoutLeakingProviderStatus() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(requestTo("http://tempo.test/api/v2/traces/" + TRACE_ID.value()))
                .andRespond(withResourceNotFound());

        assertThat(adapter(builder).findTrace(TRACE_ID)).isEmpty();
        server.verify();
    }

    @Test
    void sendsBoundedSearchWithEncodedInternalQueryAndMapsBackendFailures() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> {
                    assertThat(request.getURI().getPath()).isEqualTo("/api/search");
                    assertThat(request.getURI().getRawQuery())
                            .contains("start=1786621500")
                            .contains("end=1786622400")
                            .contains("limit=50")
                            .contains("spss=1")
                            .contains("orders%20api")
                            .doesNotContain("orders api");
                })
                .andRespond(withServerError());
        TraceSearchCriteria criteria = new TraceSearchCriteria(
                new ServiceIdentity("orders api", "shop", "dev"),
                new TimeRange(
                        Instant.parse("2026-08-13T11:45:00Z"),
                        Instant.parse("2026-08-13T12:00:00Z")),
                false);

        assertThatThrownBy(() -> adapter(builder).search(criteria))
                .isInstanceOf(TraceBackendException.class)
                .extracting(error -> ((TraceBackendException) error).reason())
                .isEqualTo(TraceBackendException.Reason.UNAVAILABLE);
        server.verify();
    }

    @Test
    void roundsTheExclusiveUpperBoundUpSoSubsecondTracesAreNotOmitted() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> assertThat(request.getURI().getRawQuery()).contains("end=1786622401"))
                .andRespond(withSuccess("{\"traces\":[]}", MediaType.APPLICATION_JSON));
        TraceSearchCriteria criteria = new TraceSearchCriteria(
                new ServiceIdentity("orders", "shop", "dev"),
                new TimeRange(Instant.parse("2026-08-13T11:45:00.100Z"), Instant.parse("2026-08-13T12:00:00.001Z")),
                false);

        assertThat(adapter(builder).search(criteria)).isEmpty();
        server.verify();
    }

    @Test
    void treatsInvalidJsonAsAMalformedProviderResponse() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(requestTo("http://tempo.test/api/v2/traces/" + TRACE_ID.value()))
                .andRespond(withSuccess("not-json", MediaType.APPLICATION_JSON));

        assertThatThrownBy(() -> adapter(builder).findTrace(TRACE_ID))
                .isInstanceOf(TraceBackendException.class)
                .extracting(error -> ((TraceBackendException) error).reason())
                .isEqualTo(TraceBackendException.Reason.MALFORMED_RESPONSE);
        server.verify();
    }

    @Test
    void requestsOneExtraBoundedClientBearingCandidateWithoutFetchingEmptyDetails() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> {
                    assertThat(request.getURI().getPath()).isEqualTo("/api/search");
                    assertThat(request.getURI().getRawQuery())
                            .contains("limit=51")
                            .contains("spss=1")
                            .contains("kind%20%3D%20client")
                            .doesNotContain("kind%20%3D%20server")
                            .contains("dev%20blue");
                })
                .andRespond(withSuccess("{\"traces\":[]}", MediaType.APPLICATION_JSON));
        TempoTraceAdapter adapter = adapter(builder);

        var result = adapter.findDependencyCandidates(new TraceDependencyQuery(
                "dev blue",
                new TimeRange(
                        Instant.parse("2026-08-13T11:45:00Z"),
                        Instant.parse("2026-08-13T12:00:00Z"))));

        assertThat(result.traces()).isEmpty();
        assertThat(result.truncated()).isFalse();
        server.verify();
        adapter.close();
    }

    @Test
    void appliesTheOverallBudgetToCandidateSearch() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://tempo.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/api/search"))
                .andRespond(request -> {
                    try {
                        Thread.sleep(250);
                    } catch (InterruptedException exception) {
                        Thread.currentThread().interrupt();
                    }
                    return withSuccess("{\"traces\":[]}", MediaType.APPLICATION_JSON)
                            .createResponse(request);
                });
        ThreadPoolExecutor executor = executor(1, 2);
        TempoTraceAdapter adapter = new TempoTraceAdapter(
                builder.build(), new ObjectMapper(), executor, Duration.ofMillis(25));

        assertThatThrownBy(() -> adapter.findDependencyCandidates(dependencyQuery()))
                .isInstanceOf(TraceBackendException.class)
                .extracting(error -> ((TraceBackendException) error).reason())
                .isEqualTo(TraceBackendException.Reason.TIMEOUT);
        adapter.close();
    }

    @Test
    void rejectsCandidateWorkWhenTheBoundedExecutorIsSaturated() throws Exception {
        ThreadPoolExecutor executor = executor(1, 1);
        CountDownLatch running = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        executor.submit(() -> {
            running.countDown();
            try {
                release.await();
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
            }
        });
        assertThat(running.await(1, TimeUnit.SECONDS)).isTrue();
        executor.submit(() -> { });
        TempoTraceAdapter adapter = new TempoTraceAdapter(
                RestClient.builder().baseUrl("http://tempo.test").build(),
                new ObjectMapper(),
                executor,
                Duration.ofSeconds(1));

        assertThatThrownBy(() -> adapter.findDependencyCandidates(dependencyQuery()))
                .isInstanceOf(TraceBackendException.class)
                .extracting(error -> ((TraceBackendException) error).reason())
                .isEqualTo(TraceBackendException.Reason.UNAVAILABLE);
        release.countDown();
        adapter.close();
    }

    private static TraceDependencyQuery dependencyQuery() {
        return new TraceDependencyQuery(
                "dev",
                new TimeRange(
                        Instant.parse("2026-08-13T11:45:00Z"),
                        Instant.parse("2026-08-13T12:00:00Z")));
    }

    private static ThreadPoolExecutor executor(int threads, int queueCapacity) {
        return new ThreadPoolExecutor(
                threads,
                threads,
                0,
                TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(queueCapacity));
    }

    private static TempoTraceAdapter adapter(RestClient.Builder builder) {
        return new TempoTraceAdapter(builder.build(), new ObjectMapper());
    }
}
