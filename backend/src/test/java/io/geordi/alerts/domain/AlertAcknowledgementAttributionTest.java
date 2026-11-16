package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertAcknowledgementAttributionTest {
    @Test
    void legacyConstructionCannotInventAuthenticatedIdentity() {
        var acknowledgement = new AlertEpisodeAcknowledgement(
                AlertEpisodeId.opened("policy", Instant.EPOCH), "operator@example.test", null, Instant.EPOCH);
        assertThat(acknowledgement.attribution()).isEqualTo(AlertAcknowledgementAttribution.legacy());
        assertThat(acknowledgement.attribution().identity()).isNull();
        assertThat(acknowledgement.attribution().displayName()).isNull();
    }

    @Test
    void malformedStoredIssuerHasABoundedFailure() {
        assertThatThrownBy(() -> AlertAcknowledgementAttribution.authenticated(
                "https://issuer.example/%identity-sentinel", "subject", null))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("invalid attribution issuer").hasNoCause();
    }

    @Test
    void snapshotPreservesExactNameAndUsesBoundedFallback() {
        var attribution = AlertAcknowledgementAttribution.authenticated("https://issuer.example", "subject", " Name ");
        assertThat(attribution.actor()).isEqualTo(" Name ");
        assertThat(attribution.identity().issuer()).isEqualTo("https://issuer.example");
        assertThat(attribution.identity().subject()).isEqualTo("subject");
        assertThat(AlertAcknowledgementAttribution.authenticated("https://issuer.example", "subject", null).actor())
                .isEqualTo("Authenticated principal");
        assertThatThrownBy(() -> AlertAcknowledgementAttribution.authenticated("https://issuer.example", "", null))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> AlertAcknowledgementAttribution.authenticated("https://issuer.example", "subject", "bad\n"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
