package io.geordi.traces.adapter.out.tempo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.SpanKind;
import io.geordi.traces.domain.SpanStatus;
import io.geordi.traces.domain.TelemetryOrigin;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceId;
import java.time.Instant;
import java.util.Base64;
import org.junit.jupiter.api.Test;

class TempoMappingTest {

    private static final Instant FROM = Instant.parse("2026-08-13T11:45:00Z");
    private static final Instant TO = Instant.parse("2026-08-13T12:00:00Z");
    private static final TimeRange RANGE = new TimeRange(FROM, TO);
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders\"api", "shop", "dev");
    private static final ObjectMapper MAPPER = new ObjectMapper();

    @Test
    void translatesExactMonitoredCompositeIdentityWithoutLeakingTraceQl() {
        String query = new TempoQueryTranslator().searchQuery(
                new TraceSearchCriteria(SERVICE, RANGE, true));

        assertThat(query)
                .contains("resource.geordi.telemetry.origin = \"monitored\"")
                .contains("resource.service.name = \"orders\\\"api\"")
                .contains("resource.service.namespace = \"shop\"")
                .contains("resource.deployment.environment.name = \"dev\"")
                .contains("status = error")
                .contains("select(resource.service.name");
    }

    @Test
    void treatsMissingNamespaceAsAnExactIdentityValue() {
        String query = new TempoQueryTranslator().searchQuery(new TraceSearchCriteria(
                new ServiceIdentity("orders", null, "dev"), RANGE, false));

        assertThat(query).contains("resource.service.namespace = nil")
                .doesNotContain("resource.service.namespace = \"\"");
    }

    @Test
    void translatesClientBearingCandidatesForOneExactEnvironment() {
        String query = new TempoQueryTranslator().dependencyCandidatesQuery("dev\"blue");

        assertThat(query)
                .contains("kind = client")
                .contains("resource.geordi.telemetry.origin = \"monitored\"")
                .contains("resource.deployment.environment.name = \"dev\\\"blue\"")
                .doesNotContain(">")
                .doesNotContain("kind = server")
                .doesNotContain("service.name");
    }

    @Test
    void mapsDistinctCandidateTraceIdentifiersWithoutRequiringProviderSummaryFields() throws Exception {
        String json = """
                {"traces":[
                  {"traceID":"1"},
                  {"traceID":"00000000000000000000000000000002"},
                  {"traceID":"1"}
                ]}
                """;

        assertThat(new TempoResponseParser().candidateTraceIds(MAPPER.readTree(json)))
                .extracting(TraceId::value)
                .containsExactly(
                        "00000000000000000000000000000001",
                        "00000000000000000000000000000002");
    }

    @Test
    void discoversOnlyCompleteMonitoredTuplesInsideTheHalfOpenRange() throws Exception {
        String json = """
                {"traces":[
                  {"traceID":"0123456789abcdef0123456789abcdef","rootTraceName":"GET /orders",
                   "startTimeUnixNano":"1786622399000000000","durationMs":10,
                   "spanSets":[{"spans":[{"spanID":"0123456789abcdef",
                     "startTimeUnixNano":"1786622399000000000","durationNanos":"10000000",
                     "attributes":[
                       {"key":"service.name","value":{"stringValue":"orders"}},
                       {"key":"service.namespace","value":{"stringValue":"shop"}},
                       {"key":"deployment.environment.name","value":{"stringValue":"dev"}},
                       {"key":"geordi.telemetry.origin","value":{"stringValue":"monitored"}}
                     ]}]}]},
                  {"traceID":"1123456789abcdef0123456789abcdef","rootTraceName":"ignored",
                   "startTimeUnixNano":"1786622400000000000","durationMs":1,
                   "spanSets":[{"spans":[{"spanID":"1123456789abcdef",
                     "startTimeUnixNano":"1786622400000000000","durationNanos":"1",
                     "attributes":[
                       {"key":"service.name","value":{"stringValue":"boundary"}},
                       {"key":"deployment.environment.name","value":{"stringValue":"dev"}},
                       {"key":"geordi.telemetry.origin","value":{"stringValue":"monitored"}}
                     ]}]}]}
                ]}
                """;

        assertThat(new TempoResponseParser().services(MAPPER.readTree(json), RANGE))
                .containsExactly(new ServiceIdentity("orders", "shop", "dev"));
    }

    @Test
    void mapsSearchSummariesAndRequiresEvidenceOfTheRequestedTuple() throws Exception {
        String json = searchResponse("shop", "dev", "monitored");
        TraceSearchCriteria criteria = new TraceSearchCriteria(
                new ServiceIdentity("orders", "shop", "dev"), RANGE, false);

        var result = new TempoResponseParser().summaries(MAPPER.readTree(json), criteria);

        assertThat(result).singleElement().satisfies(summary -> {
            assertThat(summary.rootSpanName()).isEqualTo("GET /orders");
            assertThat(summary.duration().toNanos()).isEqualTo(12_000_000);
            assertThat(summary.spanCount()).isEqualTo(3);
            assertThat(summary.error()).isTrue();
        });

        assertThatThrownBy(() -> new TempoResponseParser().summaries(
                        MAPPER.readTree(searchResponse("other", "dev", "monitored")), criteria))
                .isInstanceOf(TraceBackendException.class)
                .extracting(error -> ((TraceBackendException) error).reason())
                .isEqualTo(TraceBackendException.Reason.MALFORMED_RESPONSE);
    }

    @Test
    void mapsTempoOmittedZeroSummaryFieldsToCanonicalZero() throws Exception {
        String json = searchResponse("shop", "dev", "monitored")
                .replace(",\"durationMs\":12", "")
                .replace(",\"errorCount\":1", "")
                .replace("0123456789abcdef0123456789abcdef", "123456789abcdef0123456789abcdef");
        TraceSearchCriteria criteria = new TraceSearchCriteria(
                new ServiceIdentity("orders", "shop", "dev"), RANGE, false);

        assertThat(new TempoResponseParser().summaries(MAPPER.readTree(json), criteria))
                .singleElement().satisfies(summary -> {
                    assertThat(summary.duration().isZero()).isTrue();
                    assertThat(summary.error()).isFalse();
                    assertThat(summary.traceId().value()).isEqualTo("0123456789abcdef0123456789abcdef");
                });
    }

    @Test
    void mapsCompleteOtlpDetailIncludingStableHttpAndResourceFields() throws Exception {
        String traceHex = "0123456789abcdef0123456789abcdef";
        String rootHex = "0123456789abcdef";
        String childHex = "1123456789abcdef";
        String json = """
                {"trace":{"resourceSpans":[{"resource":{"attributes":[
                  {"key":"service.name","value":{"stringValue":"orders"}},
                  {"key":"service.namespace","value":{"stringValue":"shop"}},
                  {"key":"deployment.environment.name","value":{"stringValue":"dev"}},
                  {"key":"geordi.telemetry.origin","value":{"stringValue":"monitored"}}
                ]},"scopeSpans":[{"spans":[
                  {"traceId":"%s","spanId":"%s","name":"GET /orders","kind":"SPAN_KIND_SERVER",
                   "startTimeUnixNano":"1786622399000000000","endTimeUnixNano":"1786622399050000000",
                   "attributes":[
                     {"key":"http.request.method","value":{"stringValue":"GET"}},
                     {"key":"http.route","value":{"stringValue":"/orders"}},
                     {"key":"url.path","value":{"stringValue":"/orders/42"}},
                     {"key":"http.response.status_code","value":{"intValue":"500"}},
                     {"key":"server.address","value":{"stringValue":"orders.local"}},
                     {"key":"server.port","value":{"intValue":"8080"}},
                     {"key":"error.type","value":{"stringValue":"500"}}
                   ],"status":{"code":"STATUS_CODE_ERROR"}},
                  {"traceId":"%s","spanId":"%s","parentSpanId":"%s","name":"lookup",
                   "kind":"SPAN_KIND_INTERNAL","startTimeUnixNano":"1786622399010000000",
                   "endTimeUnixNano":"1786622399020000000","status":{"code":"STATUS_CODE_OK"}}
                ]}]}]},"status":"COMPLETE"}
                """.formatted(base64(traceHex), base64(rootHex), base64(traceHex), base64(childHex), base64(rootHex));

        var detail = new TempoResponseParser().detail(
                MAPPER.readTree(json), new TraceId(traceHex));

        assertThat(detail.spanCount()).isEqualTo(2);
        assertThat(detail.duration().toNanos()).isEqualTo(50_000_000);
        assertThat(detail.spans().getFirst().span()).satisfies(span -> {
            assertThat(span.traceId().value()).isEqualTo(traceHex);
            assertThat(span.kind()).isEqualTo(SpanKind.SERVER);
            assertThat(span.status()).isEqualTo(SpanStatus.ERROR);
            assertThat(span.service().telemetryOrigin()).isEqualTo(TelemetryOrigin.MONITORED);
            assertThat(span.error()).isTrue();
            assertThat(span.errorType()).isEqualTo("500");
            assertThat(span.http().requestMethod()).isEqualTo("GET");
            assertThat(span.http().responseStatusCode()).isEqualTo(500);
        });
        assertThat(detail.spans().get(1).startOffsetNanos()).isEqualTo(10_000_000);
    }

    @Test
    void rejectsPartialMismatchedAndMalformedProviderDetails() throws Exception {
        TraceId requested = new TraceId("0123456789abcdef0123456789abcdef");
        String partial = "{\"trace\":{\"resourceSpans\":[]},\"status\":\"PARTIAL\"}";

        assertThatThrownBy(() -> new TempoResponseParser().detail(MAPPER.readTree(partial), requested))
                .isInstanceOf(TraceBackendException.class);
    }

    private static String searchResponse(String namespace, String environment, String origin) {
        return """
                {"traces":[{"traceID":"0123456789abcdef0123456789abcdef",
                  "rootServiceName":"orders","rootTraceName":"GET /orders",
                  "startTimeUnixNano":"1786622399000000000","durationMs":12,
                  "serviceStats":{"orders":{"spanCount":3,"errorCount":1}},
                  "spanSets":[{"spans":[{"spanID":"0123456789abcdef",
                    "startTimeUnixNano":"1786622399000000000","durationNanos":"12000000",
                    "attributes":[
                      {"key":"service.name","value":{"stringValue":"orders"}},
                      {"key":"service.namespace","value":{"stringValue":"%s"}},
                      {"key":"deployment.environment.name","value":{"stringValue":"%s"}},
                      {"key":"geordi.telemetry.origin","value":{"stringValue":"%s"}}
                    ]}]}]}]}
                """.formatted(namespace, environment, origin);
    }

    private static String base64(String hex) {
        byte[] bytes = new byte[hex.length() / 2];
        for (int index = 0; index < bytes.length; index++) {
            bytes[index] = (byte) Integer.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
        }
        return Base64.getEncoder().encodeToString(bytes);
    }
}
