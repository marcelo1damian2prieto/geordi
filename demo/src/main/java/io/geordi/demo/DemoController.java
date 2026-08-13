package io.geordi.demo;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/demo")
class DemoController {

    private static final Tracer TRACER = GlobalOpenTelemetry.getTracer("io.geordi.demo");

    @GetMapping("/success")
    String success() {
        return "ok";
    }

    @GetMapping("/error")
    String error() {
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "controlled demo error");
    }

    @GetMapping("/slow")
    String slow() throws InterruptedException {
        Span span = TRACER.spanBuilder("demo.slow.work")
                .setSpanKind(SpanKind.INTERNAL)
                .startSpan();
        try (var ignored = span.makeCurrent()) {
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
