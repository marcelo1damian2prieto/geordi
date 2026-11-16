package io.geordi.selfobservability.adapter.security.export;

import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.trace.data.DelegatingSpanData;
import io.opentelemetry.sdk.trace.data.EventData;
import io.opentelemetry.sdk.trace.data.SpanData;
import io.opentelemetry.sdk.trace.data.StatusData;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;

/** Source-side privacy boundary, including automatic client and malformed-request spans. */
public final class SecuritySpanExporter implements SpanExporter {
    private static final Set<String> METHODS = Set.of("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "CONNECT");
    private final SpanExporter delegate;

    public SecuritySpanExporter(SpanExporter delegate) {
        this.delegate = Objects.requireNonNull(delegate);
    }

    @Override
    public CompletableResultCode export(Collection<SpanData> spans) {
        return delegate.export(spans.stream().map(SecuritySpanExporter::sanitize).toList());
    }

    static SpanData sanitize(SpanData span) {
        if (!"geordi-backend".equals(span.getResource().getAttribute(AttributeKey.stringKey("service.name")))) return span;
        return new DelegatingSpanData(span) {
            @Override
            public Attributes getAttributes() {
                return safeAttributes(super.getAttributes());
            }

            @Override
            public List<EventData> getEvents() {
                return super.getEvents().stream().map(event -> EventData.create(event.getEpochNanos(),
                        "exception".equals(event.getName()) ? "exception" : "platform.event",
                        safeAttributes(event.getAttributes()), safeAttributes(event.getAttributes()).size())).toList();
            }

            @Override
            public StatusData getStatus() {
                return StatusData.create(super.getStatus().getStatusCode(), "");
            }

            @Override
            public String getName() {
                String method = super.getAttributes().get(AttributeKey.stringKey("http.request.method"));
                if (method == null) method = super.getAttributes().get(AttributeKey.stringKey("http.method"));
                if (method != null) return METHODS.contains(method) ? method : "HTTP";
                return super.getName();
            }
        };
    }

    private static Attributes safeAttributes(Attributes attributes) {
        return attributes.toBuilder().removeIf(key -> {
            String name = key.getKey().toLowerCase(Locale.ROOT);
            return name.equals("url.full") || name.equals("url.query") || name.equals("url.path")
                    || name.equals("http.target") || name.equals("http.url") || name.equals("http.route")
                    || name.startsWith("http.request.header.") || name.startsWith("http.response.header.")
                    || name.contains("body") || name.equals("exception.message") || name.equals("exception.stacktrace");
        }).build();
    }

    @Override
    public CompletableResultCode flush() {
        return delegate.flush();
    }

    @Override
    public CompletableResultCode shutdown() {
        return delegate.shutdown();
    }
}
