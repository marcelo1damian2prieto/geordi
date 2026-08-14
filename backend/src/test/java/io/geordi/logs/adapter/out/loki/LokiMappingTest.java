package io.geordi.logs.adapter.out.loki;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsBackendException;
import io.geordi.logs.domain.LogSeverity;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.SpanId;
import io.geordi.logs.domain.TimeRange;
import io.geordi.logs.domain.TraceId;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class LokiMappingTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final TimeRange RANGE = new TimeRange(
            Instant.parse("2026-08-14T11:45:00Z"), Instant.parse("2026-08-14T12:00:00Z"));
    private static final ServiceIdentity SERVICE = new ServiceIdentity("orders\"api", "shop", "dev");

    @Test
    void translatesExactMonitoredIdentityAndStructuredMetadataFilters() {
        LogSearchCriteria criteria = new LogSearchCriteria(
                SERVICE,
                RANGE,
                LogSeverity.ERROR,
                "payment \"failed\"",
                new TraceId("0123456789abcdef0123456789abcdef"),
                new SpanId("0123456789abcdef"),
                100);

        String query = new LokiQueryTranslator().searchQuery(criteria);

        assertThat(query)
                .startsWith("{geordi_telemetry_origin=\"monitored\"")
                .contains("service_name=\"orders\\\"api\"")
                .contains("service_namespace=\"shop\"")
                .contains("deployment_environment_name=\"dev\"")
                .contains("severity_number >= 17 and severity_number <= 20")
                .contains("__error__=\"\"")
                .contains("|= \"payment \\\"failed\\\"\"")
                .contains("| trace_id=\"0123456789abcdef0123456789abcdef\"")
                .contains("| span_id=\"0123456789abcdef\"");
        assertThat(query.substring(0, query.indexOf('}')))
                .doesNotContain("trace_id", "span_id", "severity_number");
    }

    @Test
    void treatsMissingNamespaceAsExactAbsence() {
        String query = new LokiQueryTranslator().searchQuery(new LogSearchCriteria(
                new ServiceIdentity("orders", null, "dev"), RANGE, null, null, null, null, 100));

        assertThat(query).contains("service_namespace=\"\"");
    }

    @Test
    void mapsNativeOtlpStreamMetadataAndNanosecondTimestamps() throws Exception {
        String json = """
                {"status":"success","data":{"resultType":"streams","result":[{
                  "stream":{
                    "service_name":"orders\\\"api","service_namespace":"shop",
                    "deployment_environment_name":"dev","geordi_telemetry_origin":"monitored"
                  },
                  "values":[["1786708799123456789","Payment failed",{
                    "observed_timestamp":"1786708799123456790","severity_number":"17",
                    "severity_text":"ERROR","trace_id":"0123456789abcdef0123456789abcdef",
                    "span_id":"0123456789abcdef","scope_name":"checkout","http_request_id":"request-42"
                  }]]
                }]}}
                """;
        LogSearchCriteria criteria = new LogSearchCriteria(
                SERVICE, RANGE, LogSeverity.ERROR, "Payment", new TraceId("0123456789abcdef0123456789abcdef"),
                new SpanId("0123456789abcdef"), 100);

        var records = new LokiResponseParser().logs(MAPPER.readTree(json), criteria);

        assertThat(records).singleElement().satisfies(record -> {
            assertThat(record.timestamp()).isEqualTo(Instant.parse("2026-08-14T11:59:59.123456789Z"));
            assertThat(record.observedTimestamp()).isEqualTo(Instant.parse("2026-08-14T11:59:59.123456790Z"));
            assertThat(record.severity()).isEqualTo(LogSeverity.ERROR);
            assertThat(record.severityText()).isEqualTo("ERROR");
            assertThat(record.body()).isEqualTo("Payment failed");
            assertThat(record.traceId().value()).isEqualTo("0123456789abcdef0123456789abcdef");
            assertThat(record.spanId().value()).isEqualTo("0123456789abcdef");
            assertThat(record.attributes()).containsExactly(
                    java.util.Map.entry("http_request_id", "request-42"),
                    java.util.Map.entry("scope_name", "checkout"));
        });
    }

    @Test
    void discoversOnlyCompleteMonitoredTuplesAndRejectsContaminatedOrMalformedData() throws Exception {
        String series = """
                {"status":"success","data":[
                  {"service_name":"orders","service_namespace":"shop","deployment_environment_name":"dev","geordi_telemetry_origin":"monitored"},
                  {"service_name":"platform","deployment_environment_name":"dev","geordi_telemetry_origin":"platform"},
                  {"service_name":"missing-env","geordi_telemetry_origin":"monitored"}
                ]}
                """;
        assertThat(new LokiResponseParser().services(MAPPER.readTree(series)))
                .containsExactly(new ServiceIdentity("orders", "shop", "dev"));

        String contaminated = """
                {"status":"success","data":{"resultType":"streams","result":[{
                  "stream":{"service_name":"payments","service_namespace":"shop",
                    "deployment_environment_name":"dev","geordi_telemetry_origin":"monitored"},
                  "values":[["1786708799123456789","wrong service"]]
                }]}}
                """;
        LogSearchCriteria criteria = new LogSearchCriteria(
                new ServiceIdentity("orders", "shop", "dev"), RANGE, null, null, null, null, 100);
        assertThatThrownBy(() -> new LokiResponseParser().logs(MAPPER.readTree(contaminated), criteria))
                .isInstanceOf(LogsBackendException.class);
        assertThatThrownBy(() -> new LokiResponseParser().logs(MAPPER.readTree("{}"), criteria))
                .isInstanceOf(LogsBackendException.class);
    }
}
