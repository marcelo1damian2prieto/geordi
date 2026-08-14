package io.geordi.logs.adapter.out.loki;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.LogsBackendException;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

class LokiLogsAdapterTest {

    private static final TimeRange RANGE = new TimeRange(
            Instant.parse("2026-08-14T11:45:00Z"), Instant.parse("2026-08-14T12:00:00Z"));

    @Test
    void sendsNanosecondBoundedBackwardSearchWithEncodedInternalQuery() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://loki.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> {
                    assertThat(request.getURI().getPath()).isEqualTo("/loki/api/v1/query_range");
                    assertThat(request.getURI().getRawQuery())
                            .contains("start=1786707900000000000")
                            .contains("end=1786708800000000000")
                            .contains("direction=backward")
                            .contains("limit=25")
                            .contains("service_name")
                            .doesNotContain("orders api");
                })
                .andRespond(withSuccess(
                        "{\"status\":\"success\",\"data\":{\"resultType\":\"streams\",\"result\":[]}}",
                        MediaType.APPLICATION_JSON));
        LogSearchCriteria criteria = new LogSearchCriteria(
                new ServiceIdentity("orders api", null, "dev"), RANGE, null, null, null, null, 25);

        assertThat(adapter(builder).search(criteria)).isEmpty();
        server.verify();
    }

    @Test
    void usesSeriesForExactTupleDiscoveryAndClassifiesFailures() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://loki.test");
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        server.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/loki/api/v1/series"))
                .andRespond(withServerError());

        assertThatThrownBy(() -> adapter(builder).findServices(RANGE))
                .isInstanceOf(LogsBackendException.class)
                .extracting(error -> ((LogsBackendException) error).reason())
                .isEqualTo(LogsBackendException.Reason.UNAVAILABLE);
        server.verify();
    }

    @Test
    void treatsInvalidJsonAsMalformedAndProbeFailuresAsDown() {
        RestClient.Builder invalidBuilder = RestClient.builder().baseUrl("http://loki.test");
        MockRestServiceServer invalidServer = MockRestServiceServer.bindTo(invalidBuilder).build();
        invalidServer.expect(request -> { })
                .andRespond(withSuccess("not-json", MediaType.APPLICATION_JSON));
        assertThatThrownBy(() -> adapter(invalidBuilder).findServices(RANGE))
                .isInstanceOf(LogsBackendException.class)
                .extracting(error -> ((LogsBackendException) error).reason())
                .isEqualTo(LogsBackendException.Reason.MALFORMED_RESPONSE);

        RestClient.Builder probeBuilder = RestClient.builder().baseUrl("http://loki.test");
        MockRestServiceServer probeServer = MockRestServiceServer.bindTo(probeBuilder).build();
        probeServer.expect(request -> assertThat(request.getURI().getPath()).isEqualTo("/loki/api/v1/query_range"))
                .andRespond(withServerError());
        assertThat(adapter(probeBuilder).isQueryable()).isFalse();
    }

    private static LokiLogsAdapter adapter(RestClient.Builder builder) {
        return new LokiLogsAdapter(builder.build(), new ObjectMapper());
    }
}
