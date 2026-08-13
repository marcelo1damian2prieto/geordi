package io.geordi.metrics.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class MetricsDomainTest {

    private static final Instant NOW = Instant.parse("2026-08-13T12:00:00Z");

    @Test
    void validatesTheBoundedTimeRangeAndSelectsAtMostThreeHundredPoints() {
        TimeRange sixHours = new TimeRange(NOW.minusSeconds(21_600), NOW);

        assertThat(sixHours.resolution()).hasSeconds(72);
        assertThatThrownBy(() -> new TimeRange(NOW, NOW)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TimeRange(NOW, NOW.minusSeconds(1)))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TimeRange(NOW.minusSeconds(21_601), NOW))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void validatesCompositeServiceIdentityAndFiniteMetricPoints() {
        assertThat(new ServiceIdentity("orders", "shop", "dev").namespace()).isEqualTo("shop");
        assertThat(new ServiceIdentity("orders", " ", "dev").namespace()).isNull();
        assertThatThrownBy(() -> new ServiceIdentity(" ", null, "dev"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new MetricPoint(NOW, Double.NaN))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
