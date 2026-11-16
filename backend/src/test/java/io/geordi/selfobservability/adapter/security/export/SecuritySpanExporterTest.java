package io.geordi.selfobservability.adapter.security.export;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.data.EventData;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.data.StatusData;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import java.util.Collection;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class SecuritySpanExporterTest {
    @Test
    void sanitizesAutomaticServerAndTokenExchangeSpansBeforeExportWithoutDroppingPositiveControls() {
        var delegate = mock(SpanExporter.class);
        when(delegate.export(any())).thenReturn(CompletableResultCode.ofSuccess());
        var source = mock(SpanData.class);
        when(source.getResource()).thenReturn(Resource.create(Attributes.of(
                AttributeKey.stringKey("service.name"), "geordi-backend")));
        when(source.getName()).thenReturn("GET /login/oauth2/code/geordi?code=credential-sentinel");
        when(source.getAttributes()).thenReturn(Attributes.builder()
                .put("http.request.method", "GET").put("url.full", "https://auth.localhost/?code=credential-sentinel")
                .put("url.query", "state=credential-sentinel").put("http.target", "/?code=credential-sentinel")
                .put("http.request.header.authorization", "credential-sentinel")
                .put("http.response.header.set-cookie", "credential-sentinel")
                .put("geordi.positive_control", "present").build());
        when(source.getEvents()).thenReturn(List.of(EventData.create(1, "exception",
                Attributes.builder().put("exception.message", "credential-sentinel")
                        .put("exception.stacktrace", "credential-sentinel").put("geordi.positive_control", "event").build())));
        when(source.getStatus()).thenReturn(StatusData.create(StatusCode.ERROR, "credential-sentinel"));
        new SecuritySpanExporter(delegate).export(List.of(source));
        @SuppressWarnings("unchecked")
        ArgumentCaptor<Collection<SpanData>> capture = ArgumentCaptor.forClass(Collection.class);
        verify(delegate).export(capture.capture());
        var exported = capture.getValue().iterator().next();
        assertThat(exported.getName()).isEqualTo("GET");
        assertThat(exported.getAttributes().toString()).doesNotContain("credential-sentinel");
        assertThat(exported.getAttributes().get(AttributeKey.stringKey("geordi.positive_control"))).isEqualTo("present");
        assertThat(exported.getEvents()).hasSize(1);
        assertThat(exported.getEvents().getFirst().getAttributes().toString()).doesNotContain("credential-sentinel");
        assertThat(exported.getEvents().getFirst().getAttributes().get(AttributeKey.stringKey("geordi.positive_control")))
                .isEqualTo("event");
        assertThat(exported.getStatus().getStatusCode()).isEqualTo(StatusCode.ERROR);
        assertThat(exported.getStatus().getDescription()).isEmpty();
    }

    @Test
    void monitoredApplicationTelemetryIsNotRewritten() {
        var source = mock(SpanData.class);
        when(source.getResource()).thenReturn(Resource.create(Attributes.of(
                AttributeKey.stringKey("service.name"), "geordi-demo-service")));
        assertThat(SecuritySpanExporter.sanitize(source)).isSameAs(source);
    }
}
