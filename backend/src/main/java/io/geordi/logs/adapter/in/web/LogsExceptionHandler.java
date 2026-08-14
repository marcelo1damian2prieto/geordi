package io.geordi.logs.adapter.in.web;

import io.geordi.logs.application.LogsBackendException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

@RestControllerAdvice(assignableTypes = LogsController.class)
public class LogsExceptionHandler {

    @ExceptionHandler({
        IllegalArgumentException.class,
        MethodArgumentTypeMismatchException.class,
        MissingServletRequestParameterException.class
    })
    ProblemDetail invalidRequest(Exception exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid logs request", "Invalid logs request");
    }

    @ExceptionHandler(LogsBackendException.class)
    ProblemDetail backendFailure(LogsBackendException exception) {
        return switch (exception.reason()) {
            case MALFORMED_RESPONSE -> problem(
                    HttpStatus.BAD_GATEWAY, "Log storage response invalid", "Log storage returned invalid data");
            case TIMEOUT -> problem(
                    HttpStatus.GATEWAY_TIMEOUT, "Log storage timeout", "Log storage timed out");
            case UNAVAILABLE -> problem(
                    HttpStatus.SERVICE_UNAVAILABLE, "Log storage unavailable", "Log storage is unavailable");
        };
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
