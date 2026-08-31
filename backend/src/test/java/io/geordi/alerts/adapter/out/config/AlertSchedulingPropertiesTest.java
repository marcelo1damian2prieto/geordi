package io.geordi.alerts.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import org.junit.jupiter.api.Test;

class AlertSchedulingPropertiesTest {

    @Test
    void preservesTheEnabledFlagAndAppliesOperationalDefaults() {
        var properties = new AlertSchedulingProperties(false, null, null, null, null);

        assertThat(properties.enabled()).isFalse();
        assertThat(properties.interval()).isEqualTo(Duration.ofMinutes(1));
        assertThat(properties.workerCount()).isEqualTo(2);
        assertThat(properties.queueCapacity()).isEqualTo(10);
        assertThat(properties.shutdownGracePeriod()).isEqualTo(Duration.ofSeconds(5));
    }

    @Test
    void acceptsInclusiveExecutionBounds() {
        var minimum = new AlertSchedulingProperties(
                true, Duration.ofSeconds(10), 1, 0, Duration.ofSeconds(1));
        var maximum = new AlertSchedulingProperties(
                true, Duration.ofMinutes(15), 4, 50, Duration.ofSeconds(30));

        assertThat(minimum.interval()).isEqualTo(Duration.ofSeconds(10));
        assertThat(minimum.workerCount()).isEqualTo(1);
        assertThat(minimum.queueCapacity()).isZero();
        assertThat(minimum.shutdownGracePeriod()).isEqualTo(Duration.ofSeconds(1));
        assertThat(maximum.interval()).isEqualTo(Duration.ofMinutes(15));
        assertThat(maximum.workerCount()).isEqualTo(4);
        assertThat(maximum.queueCapacity()).isEqualTo(50);
        assertThat(maximum.shutdownGracePeriod()).isEqualTo(Duration.ofSeconds(30));
    }

    @Test
    void rejectsIntervalsOutsideTheSupportedRange() {
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofSeconds(9), 2, 10, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling interval must be between 10 seconds and 15 minutes");
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(16), 2, 10, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling interval must be between 10 seconds and 15 minutes");
    }

    @Test
    void rejectsExecutionBoundsOutsideTheSupportedRange() {
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 0, 10, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling execution bounds are invalid");
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 2, -1, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling execution bounds are invalid");
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 5, 10, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling execution bounds are invalid");
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 2, 51, Duration.ofSeconds(5)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling execution bounds are invalid");
    }

    @Test
    void rejectsShutdownGracePeriodsOutsideTheSupportedRange() {
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 2, 10, Duration.ofMillis(999)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling shutdown grace period must be between 1 and 30 seconds");
        assertThatThrownBy(() -> new AlertSchedulingProperties(
                true, Duration.ofMinutes(1), 2, 10, Duration.ofSeconds(31)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert scheduling shutdown grace period must be between 1 and 30 seconds");
    }
}
