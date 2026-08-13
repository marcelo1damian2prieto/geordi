package io.geordi.traces.adapter.in.web;

import io.geordi.traces.application.TraceBackendException;
import io.geordi.traces.application.TraceNotFoundException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

@RestControllerAdvice(assignableTypes = TracesController.class)
public class TracesExceptionHandler {

    @ExceptionHandler({
        IllegalArgumentException.class,
        MethodArgumentTypeMismatchException.class,
        MissingServletRequestParameterException.class
    })
    ProblemDetail invalidRequest(Exception exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid traces request", "Invalid traces request");
    }

    @ExceptionHandler(TraceNotFoundException.class)
    ProblemDetail notFound(TraceNotFoundException exception) {
        return problem(HttpStatus.NOT_FOUND, "Trace not found", "The requested trace was not found");
    }

    @ExceptionHandler(TraceBackendException.class)
    ProblemDetail backendFailure(TraceBackendException exception) {
        return switch (exception.reason()) {
            case MALFORMED_RESPONSE -> problem(
                    HttpStatus.BAD_GATEWAY, "Trace storage response invalid", "Trace storage returned invalid data");
            case TIMEOUT -> problem(
                    HttpStatus.GATEWAY_TIMEOUT, "Trace storage timeout", "Trace storage timed out");
            case UNAVAILABLE -> problem(
                    HttpStatus.SERVICE_UNAVAILABLE, "Trace storage unavailable", "Trace storage is unavailable");
        };
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
