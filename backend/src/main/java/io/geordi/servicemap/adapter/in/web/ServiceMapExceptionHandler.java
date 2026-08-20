package io.geordi.servicemap.adapter.in.web;

import io.geordi.servicemap.application.ServiceMapBackendException;
import java.time.format.DateTimeParseException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice(assignableTypes = ServiceMapController.class)
public class ServiceMapExceptionHandler {

    @ExceptionHandler({
        IllegalArgumentException.class,
        DateTimeParseException.class,
        MissingServletRequestParameterException.class
    })
    ProblemDetail invalidRequest(Exception exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid service map request", "Invalid service map request");
    }

    @ExceptionHandler(ServiceMapBackendException.class)
    ProblemDetail backendFailure(ServiceMapBackendException exception) {
        return switch (exception.reason()) {
            case MALFORMED_RESPONSE -> problem(
                    HttpStatus.BAD_GATEWAY,
                    "Trace storage response invalid",
                    "Trace storage returned invalid service map evidence");
            case TIMEOUT -> problem(
                    HttpStatus.GATEWAY_TIMEOUT,
                    "Trace storage timeout",
                    "Trace storage timed out while deriving the service map");
            case UNAVAILABLE -> problem(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "Trace storage unavailable",
                    "Trace storage is unavailable");
        };
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
