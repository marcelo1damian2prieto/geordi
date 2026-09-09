package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertEpisodeAcknowledgementTest {
    private static final AlertEpisodeId ID = AlertEpisodeId.opened("p", Instant.parse("2026-01-01T00:00:00Z"));

    @Test
    void acceptsCodePointBoundsAndPreservesCase() {
        String actor = "A" + "😀".repeat(127);
        assertThat(new AlertEpisodeAcknowledgement(ID, actor, " reason ", Instant.EPOCH).actor()).isEqualTo(actor);
    }

    @Test
    void rejectsActorAndReasonOverCodePointBounds() {
        assertThatThrownBy(() -> new AlertEpisodeAcknowledgement(ID, "x".repeat(129), null, Instant.EPOCH))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new AlertEpisodeAcknowledgement(ID, "a", "x".repeat(513), Instant.EPOCH))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
