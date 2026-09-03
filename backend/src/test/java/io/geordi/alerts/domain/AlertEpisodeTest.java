package io.geordi.alerts.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class AlertEpisodeTest {

    private static final String POLICY_ID = "checkout-burn";
    private static final Instant OCCURRED_AT = Instant.parse("2026-09-01T20:00:00Z");
    private static final Instant FOLLOWING_START = Instant.parse("2026-09-01T21:00:00Z");

    @Test
    void normalEpisodeIdUsesTheSpecifiedUtf8NewlineDelimitedBytesAndIsStableAcrossRetriesAndRestarts() {
        AlertEpisodeId firstAttempt = AlertEpisodeId.opened(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId retry = AlertEpisodeId.opened(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId afterRestart = AlertEpisodeId.opened(new String(POLICY_ID), Instant.parse(OCCURRED_AT.toString()));

        assertThat(firstAttempt.value()).isEqualTo("e661cfda4ee7bd34e30a03638e88acd35190cda6df670a87dd4e8c31229501e8");
        assertThat(retry).isEqualTo(firstAttempt);
        assertThat(afterRestart).isEqualTo(firstAttempt);
    }

    @Test
    void legacyEpisodeIdUsesItsExplicitNamespaceAndIsStableAcrossRetriesAndRestarts() {
        AlertEpisodeId firstAttempt = AlertEpisodeId.legacyResolved(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId retry = AlertEpisodeId.legacyResolved(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId afterRestart = AlertEpisodeId.legacyResolved(
                new String(POLICY_ID), Instant.parse(OCCURRED_AT.toString()));

        assertThat(firstAttempt.value()).isEqualTo("2173b11c004859e4135baba509822bbfd5adae8bccd9a54a556a0409ea4f3bfe");
        assertThat(retry).isEqualTo(firstAttempt);
        assertThat(afterRestart).isEqualTo(firstAttempt);
    }

    @Test
    void followingNormalEpisodeHasItsOwnIdentityAndCannotCollideWithLegacyHistory() {
        AlertEpisodeId legacy = AlertEpisodeId.legacyResolved(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId normalAtSameInstant = AlertEpisodeId.opened(POLICY_ID, OCCURRED_AT);
        AlertEpisodeId followingNormal = AlertEpisodeId.opened(POLICY_ID, FOLLOWING_START);

        assertThat(followingNormal.value()).isEqualTo("bbf40d70af604086db049ff82184d9024c07160cb2b6bcd1613c751a96e87f29");
        assertThat(normalAtSameInstant).isNotEqualTo(legacy);
        assertThat(followingNormal).isNotEqualTo(legacy);
        assertThat(followingNormal).isNotEqualTo(normalAtSameInstant);
    }

    @Test
    void legacyResolutionRetainsUnknownStartAndNeverBehavesLikeAnOpenEpisode() {
        AlertEpisode legacy = AlertEpisode.legacyResolved(POLICY_ID, OCCURRED_AT);

        assertThat(legacy.origin()).isEqualTo(AlertEpisodeOrigin.PRE_M14_UNKNOWN_START);
        assertThat(legacy.openedAt()).isNull();
        assertThat(legacy.closedAt()).isEqualTo(OCCURRED_AT);
        assertThat(legacy.open()).isFalse();
        assertThatThrownBy(() -> legacy.resolve(OCCURRED_AT.plusSeconds(1)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("closed alert episode cannot be resolved again");
    }

    @Test
    void normalEpisodeTransitionsFromOpenToClosedWithoutChangingItsCanonicalIdentity() {
        AlertEpisode opened = AlertEpisode.opened(POLICY_ID, OCCURRED_AT);

        AlertEpisode resolved = opened.resolve(OCCURRED_AT.plusSeconds(300));

        assertThat(opened.open()).isTrue();
        assertThat(opened.closedAt()).isNull();
        assertThat(resolved.id()).isEqualTo(opened.id());
        assertThat(resolved.origin()).isEqualTo(AlertEpisodeOrigin.M14);
        assertThat(resolved.openedAt()).isEqualTo(OCCURRED_AT);
        assertThat(resolved.closedAt()).isEqualTo(OCCURRED_AT.plusSeconds(300));
        assertThat(resolved.open()).isFalse();
    }
}
