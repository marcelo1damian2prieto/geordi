package io.geordi.demo;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import org.springframework.http.HttpStatus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

@RestController
@RequestMapping("/demo")
class DemoController {

    private static final Tracer TRACER = GlobalOpenTelemetry.getTracer("io.geordi.demo");
    private static final Logger LOGGER = LoggerFactory.getLogger(DemoController.class);
    private static final HttpClient HTTP_CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(2))
            .build();

    private final URI downstreamUri;

    DemoController(@Value("${demo.downstream-url:http://demo-downstream:8082/downstream/respond}") String downstreamUrl) {
        this.downstreamUri = URI.create(downstreamUrl);
    }

    @GetMapping("/success")
    String success() {
        LOGGER.info("geordi.demo.log.info");
        return "ok";
    }

    @GetMapping("/downstream")
    String downstream() throws java.io.IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(downstreamUri)
                .GET()
                .timeout(Duration.ofSeconds(3))
                .build();
        HttpResponse<String> response = HTTP_CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != HttpStatus.OK.value()) {
            throw new ResponseStatusException(HttpStatus.BAD_GATEWAY, "downstream demo response was not successful");
        }
        return response.body();
    }

    @GetMapping("/warn")
    String warn() {
        LOGGER.warn("geordi.demo.log.warn");
        return "warn";
    }

    @GetMapping("/error")
    String error() {
        LOGGER.error("geordi.demo.log.error");
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "controlled demo error");
    }

    @GetMapping("/slow")
    String slow() throws InterruptedException {
        Span span = TRACER.spanBuilder("demo.slow.work")
                .setSpanKind(SpanKind.INTERNAL)
                .startSpan();
        try (var ignored = span.makeCurrent()) {
            MDC.put("request_id", "geordi-demo-log-request");
            MDC.put("url_full", "http://geordi-demo:8081/demo/slow");
            try {
                LOGGER.info("geordi.demo.log.nested-span");
            } finally {
                MDC.remove("request_id");
                MDC.remove("url_full");
            }
            Thread.sleep(150);
            return "slow";
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            span.recordException(exception);
            span.setStatus(StatusCode.ERROR);
            throw exception;
        } finally {
            span.end();
        }
    }

    @GetMapping("/cpu")
    String cpu() {
        long accumulator = 0;
        for (int index = 0; index < 250_000; index++) {
            accumulator += (long) index * index;
        }
        return Long.toString(accumulator);
    }
}
