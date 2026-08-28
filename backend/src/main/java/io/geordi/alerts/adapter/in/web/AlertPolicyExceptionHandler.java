package io.geordi.alerts.adapter.in.web;

import io.geordi.alerts.application.AlertPolicyNotFoundException;
import io.geordi.alerts.application.AlertLifecycleConcurrencyException;
import io.geordi.alerts.application.AlertLifecyclePersistenceException;
import io.geordi.alerts.domain.AlertLifecycleBindingMismatchException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice(assignableTypes = {AlertPolicyController.class, AlertLifecycleController.class})
public class AlertPolicyExceptionHandler {

    @ExceptionHandler(IllegalArgumentException.class)
    ProblemDetail invalidRequest(IllegalArgumentException exception) {
        return problem(HttpStatus.BAD_REQUEST, "Invalid alert policy request", "Invalid alert policy request");
    }

    @ExceptionHandler(AlertPolicyNotFoundException.class)
    ProblemDetail notFound(AlertPolicyNotFoundException exception) {
        return problem(HttpStatus.NOT_FOUND, "Alert policy not found", "The requested alert policy was not found");
    }

    @ExceptionHandler(AlertLifecycleBindingMismatchException.class)
    ProblemDetail lifecycleConflict(AlertLifecycleBindingMismatchException exception) {
        return problem(
                HttpStatus.CONFLICT,
                "Alert lifecycle identity conflict",
                "Persisted lifecycle identity conflicts with the canonical alert evaluation");
    }

    @ExceptionHandler({AlertLifecycleConcurrencyException.class, AlertLifecyclePersistenceException.class})
    ProblemDetail lifecycleUnavailable(RuntimeException exception) {
        return problem(
                HttpStatus.SERVICE_UNAVAILABLE,
                "Alert lifecycle unavailable",
                "Alert lifecycle state could not be read or updated");
    }

    private static ProblemDetail problem(HttpStatus status, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setTitle(title);
        return problem;
    }
}
