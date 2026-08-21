package io.geordi.slos.adapter.in.web;

import io.geordi.slos.application.SloNotFoundException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice(assignableTypes = SloController.class)
public class SloExceptionHandler {

    @ExceptionHandler(IllegalArgumentException.class)
    ProblemDetail invalidRequest(IllegalArgumentException exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid SLO request", "Invalid SLO request");
    }

    @ExceptionHandler(SloNotFoundException.class)
    ProblemDetail notFound(SloNotFoundException exception) {
        return problem(HttpStatus.NOT_FOUND, "SLO not found", "The requested SLO was not found");
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
