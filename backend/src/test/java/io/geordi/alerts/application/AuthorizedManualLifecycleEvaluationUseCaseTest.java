package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PermissionDeniedException;
import io.geordi.core.application.security.PrincipalIdentity;
import java.util.Set;
import org.junit.jupiter.api.Test;

class AuthorizedManualLifecycleEvaluationUseCaseTest {
    private final AlertLifecycleEvaluationUseCase coordinator = mock(AlertLifecycleEvaluationUseCase.class);
    private final AuthorizedManualLifecycleEvaluationUseCase authorized =
            new AuthorizedManualLifecycleEvaluationUseCase(coordinator);

    @Test
    void deniesMissingPrincipalAndReadOnlyPrincipalBeforeDelegating() {
        assertThatThrownBy(() -> authorized.evaluate(null, "policy-1"))
                .isInstanceOf(PermissionDeniedException.class);
        assertThatThrownBy(() -> authorized.evaluate(principal(Set.of(GeordiPermission.OBSERVABILITY_READ)), "policy-1"))
                .isInstanceOf(PermissionDeniedException.class);
        verifyNoInteractions(coordinator);
    }

    @Test
    void evaluatorOnlyPrincipalCanManuallyInvokeTheSharedCoordinator() {
        authorized.evaluate(principal(Set.of(GeordiPermission.ALERT_EVALUATE)), "policy-1");
        verify(coordinator).evaluate("policy-1");
    }

    private static AuthenticatedPrincipal principal(Set<GeordiPermission> permissions) {
        return new AuthenticatedPrincipal(new PrincipalIdentity("https://issuer.example", "subject-1"),
                null, permissions, AuthenticationMechanism.BEARER);
    }
}
