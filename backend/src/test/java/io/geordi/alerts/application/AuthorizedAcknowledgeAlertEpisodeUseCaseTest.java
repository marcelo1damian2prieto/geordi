package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository;
import io.geordi.alerts.domain.AlertAcknowledgementAttribution;
import io.geordi.alerts.domain.AlertEpisodeAcknowledgement;
import io.geordi.alerts.domain.AlertEpisodeId;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PrincipalIdentity;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;
import org.junit.jupiter.api.Test;

class AuthorizedAcknowledgeAlertEpisodeUseCaseTest {
    private static final AlertEpisodeId EPISODE = new AlertEpisodeId("a".repeat(64));
    private static final Instant NOW = Instant.parse("2026-09-22T20:00:00Z");

    @Test
    void derivesDurableAttributionFromTheAuthorizedPrincipal() {
        AlertEpisodeAcknowledgementRepository repository = mock(AlertEpisodeAcknowledgementRepository.class);
        var acknowledgement = new AlertEpisodeAcknowledgement(EPISODE, "Ada Operator", "Investigating",
                NOW, AlertAcknowledgementAttribution.authenticated("https://identity.example", "operator-7", "Ada Operator"));
        when(repository.acknowledgeAuthenticated(eq(EPISODE), any(), eq("Investigating"), eq(NOW)))
                .thenReturn(new AlertEpisodeAcknowledgementRepository.Result(
                        AlertEpisodeAcknowledgementRepository.Result.Status.CREATED, acknowledgement));
        var service = new AcknowledgeAlertEpisodeService(repository, Clock.fixed(NOW, ZoneOffset.UTC));
        var useCase = new AuthorizedAcknowledgeAlertEpisodeUseCase(service);
        var principal = new AuthenticatedPrincipal(new PrincipalIdentity("https://identity.example", "operator-7"),
                "Ada Operator", Set.of(GeordiPermission.ALERT_ACKNOWLEDGE), AuthenticationMechanism.SESSION);

        useCase.acknowledge(principal, EPISODE, "  Investigating  ");

        verify(repository).acknowledgeAuthenticated(eq(EPISODE), eq(AlertAcknowledgementAttribution.authenticated(
                "https://identity.example", "operator-7", "Ada Operator")), eq("Investigating"), eq(NOW));
        verify(repository, never()).acknowledge(eq(EPISODE), any(), any(), any());
    }

    @Test
    void rejectsAnUnprivilegedPrincipalBeforePersistence() {
        AlertEpisodeAcknowledgementRepository repository = mock(AlertEpisodeAcknowledgementRepository.class);
        var useCase = new AuthorizedAcknowledgeAlertEpisodeUseCase(
                new AcknowledgeAlertEpisodeService(repository, Clock.fixed(NOW, ZoneOffset.UTC)));
        var principal = new AuthenticatedPrincipal(new PrincipalIdentity("https://identity.example", "reader-1"),
                null, Set.of(GeordiPermission.OBSERVABILITY_READ), AuthenticationMechanism.BEARER);

        assertThatThrownBy(() -> useCase.acknowledge(principal, EPISODE, null))
                .isInstanceOf(io.geordi.core.application.security.PermissionDeniedException.class);
        verify(repository, never()).acknowledgeAuthenticated(any(), any(), any(), any());
    }
}
