package io.geordi.metrics.adapter.in.web;

import io.geordi.metrics.application.MetricsBackendException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

@RestControllerAdvice(assignableTypes = MetricsController.class)
public class MetricsExceptionHandler {

    @ExceptionHandler({IllegalArgumentException.class, MethodArgumentTypeMismatchException.class})
    ProblemDetail invalidRequest(Exception exception) {
        ProblemDetail detail = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, "Invalid metrics request");
        detail.setTitle("Invalid metrics request");
        return detail;
    }

    @ExceptionHandler(MetricsBackendException.class)
    ProblemDetail backendUnavailable(MetricsBackendException exception) {
        ProblemDetail detail = ProblemDetail.forStatusAndDetail(
                HttpStatus.SERVICE_UNAVAILABLE, "Metrics storage is unavailable");
        detail.setTitle("Metrics storage unavailable");
        return detail;
    }
}
