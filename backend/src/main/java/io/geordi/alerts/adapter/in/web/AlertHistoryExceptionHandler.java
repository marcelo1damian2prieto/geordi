package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertEpisodeNotFoundException;
import io.geordi.alerts.application.AlertHistoryPersistenceException;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import java.time.format.DateTimeParseException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/** Maps public history-query validation and lookup failures to the established Problem contract. */
@RestControllerAdvice(assignableTypes = AlertHistoryController.class)
public class AlertHistoryExceptionHandler {

    @ExceptionHandler(IllegalArgumentException.class)
    ProblemDetail invalidRequest(IllegalArgumentException exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid alert history request", "Invalid alert history request");
    }

    @ExceptionHandler(DateTimeParseException.class)
    ProblemDetail invalidTimestamp(DateTimeParseException exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid alert history request", "Invalid alert history request");
    }

    @ExceptionHandler(AlertEpisodeNotFoundException.class)
    ProblemDetail notFound(AlertEpisodeNotFoundException exception) {
        return problem(HttpStatus.NOT_FOUND, "Alert episode not found", "The requested alert episode was not found");
    }

    @ExceptionHandler(AlertLifecyclePersistenceException.class)
    ProblemDetail unavailable(AlertLifecyclePersistenceException exception) {
        return problem(HttpStatus.SERVICE_UNAVAILABLE, "Alert history unavailable", "Alert history could not be read");
    }

    @ExceptionHandler(AlertHistoryPersistenceException.class)
    ProblemDetail unavailable(AlertHistoryPersistenceException exception) {
        return problem(HttpStatus.SERVICE_UNAVAILABLE, "Alert history unavailable", "Alert history could not be read");
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
