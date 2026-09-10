package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

import io.geordi.alerts.application.port.out.AlertEpisodeAcknowledgementRepository;
import io.geordi.alerts.domain.AlertEpisodeAcknowledgement;
import io.geordi.alerts.domain.AlertEpisodeId;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class AcknowledgeAlertEpisodeServiceTest {
    private static final AlertEpisodeId ID = AlertEpisodeId.opened("p", Instant.parse("2026-01-01T00:00:00Z"));
    private static final Instant NOW = Instant.parse("2026-01-01T00:00:00.123456789Z");

    @Test
    void normalizesInputAndUsesServerClock() {
        var repository = mock(AlertEpisodeAcknowledgementRepository.class);
        var value = new AlertEpisodeAcknowledgement(ID, "Operator", null, NOW);
        when(repository.acknowledge(ID, "Operator", null, NOW)).thenReturn(
                new AlertEpisodeAcknowledgementRepository.Result(
                        AlertEpisodeAcknowledgementRepository.Result.Status.CREATED, value));
        var result = new AcknowledgeAlertEpisodeService(repository, Clock.fixed(NOW, ZoneOffset.UTC))
                .acknowledge(ID, " Operator ", "   ");
        assertThat(result.status()).isEqualTo(AcknowledgeAlertEpisodeUseCase.AcknowledgementResult.Status.CREATED);
        assertThat(result.acknowledgement().acknowledgedAt()).isEqualTo(NOW);
    }

    @Test
    void rejectsInvalidActorAndReason() {
        var repository = mock(AlertEpisodeAcknowledgementRepository.class);
        var service = new AcknowledgeAlertEpisodeService(repository, Clock.systemUTC());
        assertThatThrownBy(() -> service.acknowledge(ID, " ", null)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.acknowledge(ID, "a", "x".repeat(513)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.acknowledge(ID, "😀".repeat(129), null))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> service.acknowledge(ID, "a", "😀".repeat(513)))
                .isInstanceOf(IllegalArgumentException.class);
        verifyNoInteractions(repository);
    }
}
