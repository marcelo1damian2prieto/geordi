package io.geordi.metrics.adapter.out.victoriametrics;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.metrics.application.RequestOutcomeQuery;
import io.geordi.metrics.application.RequestOutcomeQueryException;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class VictoriaMetricsRequestOutcomeTest {

    private static final Instant NOW = Instant.parse("2026-08-20T18:00:00Z");
    private static final RequestOutcomeQuery QUERY = new RequestOutcomeQuery(
            new ServiceIdentity("checkout", null, "production"),
            new TimeRange(NOW.minusSeconds(300), NOW));

    @Test
    void translatesOneWholeWindowMeasurementWithExactMonitoredIdentity() {
        String expression = new VictoriaMetricsQueryTranslator().translateRequestOutcomes(QUERY);

        assertThat(expression)
                .contains("http.server.request.duration_count")
                .contains("[300s]")
                .doesNotContain("round(")
                .contains("\"geordi.telemetry.origin\"=\"monitored\"")
                .contains("\"service.name\"=\"checkout\"")
                .contains("\"service.namespace\"=\"\"")
                .contains("\"deployment.environment.name\"=\"production\"")
                .contains("\"http.response.status_code\"=~\"5..\"");
    }

    @Test
    void parsesCoherentCountsAndProvesAbsentErrorSubsetIsZero() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        var complete = new VictoriaMetricsResponseParser().requestOutcomes(mapper.readTree("""
                {"status":"success","data":{"result":[
                  {"metric":{"geordi.slo.component":"requests"},"value":[1,"10"]},
                  {"metric":{"geordi.slo.component":"errors"},"value":[1,"2"]}
                ]}}
                """));
        var noErrors = new VictoriaMetricsResponseParser().requestOutcomes(mapper.readTree("""
                {"status":"success","data":{"result":[
                  {"metric":{"geordi.slo.component":"requests"},"value":[1,"10"]}
                ]}}
                """));

        assertThat(complete.requestCount()).isEqualTo(10d);
        assertThat(complete.errorCount()).isEqualTo(2d);
        assertThat(noErrors.requestCount()).isEqualTo(10d);
        assertThat(noErrors.errorCount()).isZero();
    }

    @Test
    void preservesMissingRequestCountAndRejectsNonFiniteOrDuplicateProviderValues() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        var missing = new VictoriaMetricsResponseParser().requestOutcomes(mapper.readTree("""
                {"status":"success","data":{"result":[]}}
                """));
        assertThat(missing.requestCount()).isNull();
        assertThat(missing.errorCount()).isNull();

        assertThatThrownBy(() -> new VictoriaMetricsResponseParser().requestOutcomes(mapper.readTree("""
                {"status":"success","data":{"result":[
                  {"metric":{"geordi.slo.component":"requests"},"value":[1,"NaN"]}
                ]}}
                """)))
                .isInstanceOf(RequestOutcomeQueryException.class)
                .extracting(exception -> ((RequestOutcomeQueryException) exception).reason())
                .isEqualTo(RequestOutcomeQueryException.Reason.INVALID_TELEMETRY);
    }
}
