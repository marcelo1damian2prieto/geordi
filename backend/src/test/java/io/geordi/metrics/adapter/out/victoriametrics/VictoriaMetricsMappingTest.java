package io.geordi.metrics.adapter.out.victoriametrics;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;
import org.springframework.http.MediaType;
import java.util.stream.Stream;

class VictoriaMetricsMappingTest {

    private static final Instant NOW = Instant.parse("2026-08-13T12:00:00Z");

    @Test
    void translatesOnlyClosedMetricsAndAlwaysRestrictsQueriesToMonitoredIdentity() {
        MetricsQuery query = MetricsQuery.of(
                new ServiceIdentity("orders\"api", "shop", "dev"),
                new TimeRange(NOW.minusSeconds(900), NOW),
                List.of(OperationalMetric.HTTP_ERROR_RATE));

        String expression = new VictoriaMetricsQueryTranslator()
                .translate(query, OperationalMetric.HTTP_ERROR_RATE);

        assertThat(expression)
                .contains("\"geordi.telemetry.origin\"=\"monitored\"")
                .contains("\"service.name\"=\"orders\\\"api\"")
                .contains("\"service.namespace\"=\"shop\"")
                .contains("\"http.response.status_code\"=~\"5..\"");
    }

    @Test
    void explicitlySeparatesUnnamespacedAndNamespacedServicesWithTheSameName() {
        VictoriaMetricsQueryTranslator translator = new VictoriaMetricsQueryTranslator();
        TimeRange range = new TimeRange(NOW.minusSeconds(900), NOW);
        MetricsQuery unnamespaced = MetricsQuery.of(
                new ServiceIdentity("orders", null, "dev"), range,
                List.of(OperationalMetric.JVM_MEMORY_USED));
        MetricsQuery namespaced = MetricsQuery.of(
                new ServiceIdentity("orders", "shop", "dev"), range,
                List.of(OperationalMetric.JVM_MEMORY_USED));

        assertThat(translator.translate(unnamespaced, OperationalMetric.JVM_MEMORY_USED))
                .contains("\"service.namespace\"=\"\"")
                .doesNotContain("\"service.namespace\"=\"shop\"");
        assertThat(translator.translate(namespaced, OperationalMetric.JVM_MEMORY_USED))
                .contains("\"service.namespace\"=\"shop\"")
                .doesNotContain("\"service.namespace\"=\"\"");
    }

    @ParameterizedTest
    @MethodSource("metricMappings")
    void translatesEveryOperationalMetricWithItsCanonicalUnitAndCriticalSemantics(
            OperationalMetric metric, String unit, String sourceMetric, String semanticFragment) {
        TimeRange range = new TimeRange(NOW.minusSeconds(900), NOW);
        MetricsQuery query = MetricsQuery.of(
                new ServiceIdentity("orders", "shop", "dev"), range, List.of(metric));

        assertThat(metric.unit()).isEqualTo(unit);
        assertThat(new VictoriaMetricsQueryTranslator().translate(query, metric))
                .contains("__name__=\"" + sourceMetric + "\"")
                .contains(semanticFragment)
                .contains("\"geordi.telemetry.origin\"=\"monitored\"")
                .contains("\"service.namespace\"=\"shop\"");
    }

    private static Stream<Arguments> metricMappings() {
        return Stream.of(
                Arguments.of(OperationalMetric.JVM_MEMORY_USED, "By", "jvm.memory.used", "sum("),
                Arguments.of(OperationalMetric.JVM_CPU_UTILIZATION, "1", "jvm.cpu.recent_utilization", "avg("),
                Arguments.of(OperationalMetric.JVM_THREAD_COUNT, "{thread}", "jvm.thread.count", "sum("),
                Arguments.of(OperationalMetric.JVM_GC_DURATION, "s", "jvm.gc.duration_sum", "[10s]"),
                Arguments.of(OperationalMetric.HTTP_REQUEST_RATE, "{request}/s",
                        "http.server.request.duration_count", "[10s]"),
                Arguments.of(OperationalMetric.HTTP_REQUEST_COUNT, "{request}",
                        "http.server.request.duration_count", "[900s]"),
                Arguments.of(OperationalMetric.HTTP_REQUEST_LATENCY_P95, "s",
                        "http.server.request.duration_bucket", "histogram_quantile(0.95"),
                Arguments.of(OperationalMetric.HTTP_ERROR_RATE, "1",
                        "http.server.request.duration_count", "[10s]"),
                Arguments.of(OperationalMetric.HTTP_ERROR_COUNT, "{request}",
                        "http.server.request.duration_count", "[900s]"));
    }

    @Test
    void gcDurationIsASecondsIncreaseAndCountsAreSelectedRangeRollingTotals() {
        TimeRange range = new TimeRange(NOW.minusSeconds(900), NOW);
        ServiceIdentity service = new ServiceIdentity("orders", "shop", "dev");
        VictoriaMetricsQueryTranslator translator = new VictoriaMetricsQueryTranslator();

        assertThat(translator.translate(
                        MetricsQuery.of(service, range, List.of(OperationalMetric.JVM_GC_DURATION)),
                        OperationalMetric.JVM_GC_DURATION))
                .contains("increase(", "[10s]")
                .doesNotContain("rate(");
        assertThat(translator.translate(
                        MetricsQuery.of(service, range, List.of(OperationalMetric.HTTP_REQUEST_COUNT)),
                        OperationalMetric.HTTP_REQUEST_COUNT))
                .contains("increase(", "[900s]")
                .doesNotContain("[3s]");
        assertThat(translator.translate(
                        MetricsQuery.of(service, range, List.of(OperationalMetric.HTTP_ERROR_COUNT)),
                        OperationalMetric.HTTP_ERROR_COUNT))
                .contains("increase(", "[900s]", "http.response.status_code")
                .doesNotContain("[3s]");
    }

    @Test
    void parsesValidSamplesAndDropsNonFiniteProviderValues() throws Exception {
        String json = """
                {"status":"success","data":{"result":[{"values":[
                  [1723550399,"4.2"],[1723550400,"NaN"]
                ]}]}}
                """;

        var series = new VictoriaMetricsResponseParser().series(
                new ObjectMapper().readTree(json), OperationalMetric.JVM_CPU_UTILIZATION);

        assertThat(series.points()).singleElement().satisfies(point -> assertThat(point.value()).isEqualTo(4.2));
    }

    @Test
    void discoversOnlyExplicitlyClassifiedMonitoredServices() throws Exception {
        String json = """
                {"status":"success","data":[
                  {"service.name":"orders","service.namespace":"shop","deployment.environment.name":"dev",
                   "geordi.telemetry.origin":"monitored"},
                  {"service.name":"geordi-backend","deployment.environment.name":"dev",
                   "geordi.telemetry.origin":"platform"}
                ]}
                """;

        assertThat(new VictoriaMetricsResponseParser().services(new ObjectMapper().readTree(json)))
                .containsExactly(new ServiceIdentity("orders", "shop", "dev"));
    }

    @Test
    void healthProbeExecutesARealScalarQueryAndRequiresAValidResponse() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://metrics.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(requestTo("http://metrics.test/api/v1/query?query=1"))
                .andRespond(withSuccess(
                        "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[0,\"1\"]}]}}",
                        MediaType.APPLICATION_JSON));

        assertThat(new VictoriaMetricsAdapter(builder.build()).isQueryable()).isTrue();
        server.verify();
    }

    @Test
    void serviceSelectorBracesAreEncodedAsAQueryParameterRatherThanExpandedAsATemplate() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://metrics.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(requestTo("http://metrics.test/api/v1/series?"
                        + "match%5B%5D=%7B%22geordi.telemetry.origin%22%3D%22monitored%22%7D"
                        + "&start=2026-08-13T11:45:00Z&end=2026-08-13T12:00:00Z"))
                .andRespond(withSuccess("{\"status\":\"success\",\"data\":[]}", MediaType.APPLICATION_JSON));

        var result = new VictoriaMetricsAdapter(builder.build()).findServices(
                new TimeRange(NOW.minusSeconds(900), NOW));

        assertThat(result).isEmpty();
        server.verify();
    }

    @Test
    void rangeExpressionBracesAreEncodedAsAQueryParameterRatherThanExpandedAsATemplate() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://metrics.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> {
                    assertThat(request.getURI().getPath()).isEqualTo("/api/v1/query_range");
                    assertThat(request.getURI().getRawQuery())
                            .contains("query=sum%28%7B__name__%3D%22jvm.memory.used%22")
                            .contains("%22geordi.telemetry.origin%22%3D%22monitored%22");
                })
                .andRespond(withSuccess(
                        "{\"status\":\"success\",\"data\":{\"result\":[]}}",
                        MediaType.APPLICATION_JSON));
        MetricsQuery query = MetricsQuery.of(
                new ServiceIdentity("orders", "shop", "dev"),
                new TimeRange(NOW.minusSeconds(900), NOW),
                List.of(OperationalMetric.JVM_MEMORY_USED));

        assertThat(new VictoriaMetricsAdapter(builder.build()).query(query)).singleElement();
        server.verify();
    }
}
