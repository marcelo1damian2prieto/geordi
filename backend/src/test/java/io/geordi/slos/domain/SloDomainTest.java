package io.geordi.slos.domain;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import org.junit.jupiter.api.Test;

class SloDomainTest {

    @Test
    void validatesDefinitionAndNormalizesExactIdentity() {
        SloDefinition definition = new SloDefinition(
                "checkout-availability", " Checkout availability ", " ",
                new ServiceIdentity(" checkout ", " commerce ", " production "),
                SliType.AVAILABILITY, new BigDecimal("0.999"), EvaluationWindow.PT1H, true);

        assertThat(definition.name()).isEqualTo("Checkout availability");
        assertThat(definition.description()).isNull();
        assertThat(definition.service()).isEqualTo(new ServiceIdentity("checkout", "commerce", "production"));
        assertThatThrownBy(() -> new SloDefinition(
                "Bad Id", "name", null, definition.service(), SliType.AVAILABILITY,
                BigDecimal.ONE, EvaluationWindow.PT5M, true))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new SloDefinition(
                "valid", "name", null, definition.service(), SliType.ERROR_RATE,
                new BigDecimal("1.001"), EvaluationWindow.PT5M, true))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void supportsOnlyTheFourConfiguredWindows() {
        assertThat(EvaluationWindow.from("PT5M")).isEqualTo(EvaluationWindow.PT5M);
        assertThat(EvaluationWindow.from("PT15M")).isEqualTo(EvaluationWindow.PT15M);
        assertThat(EvaluationWindow.from("PT1H")).isEqualTo(EvaluationWindow.PT1H);
        assertThat(EvaluationWindow.from("PT6H")).isEqualTo(EvaluationWindow.PT6H);
        assertThatThrownBy(() -> EvaluationWindow.from("PT30M"))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void derivesAllowedBadRatioFromCanonicalSliDirection() {
        assertThat(SliSemantics.allowedBadRatio(SliType.AVAILABILITY, new BigDecimal("0.999")))
                .isEqualByComparingTo("0.001");
        assertThat(SliSemantics.allowedBadRatio(SliType.ERROR_RATE, new BigDecimal("0.001")))
                .isEqualByComparingTo("0.001");
        assertThat(SliSemantics.allowedBadRatio(SliType.AVAILABILITY, BigDecimal.ONE)).isZero();
        assertThat(SliSemantics.allowedBadRatio(SliType.ERROR_RATE, BigDecimal.ZERO)).isZero();
    }

    @Test
    void enforcesAvailableAndUnavailableBurnRateInvariants() {
        BurnRateEvaluation available = BurnRateEvaluation.available(
                new BigDecimal("0.001"), new BigDecimal("0.004"), new BigDecimal("4"));
        BurnRateEvaluation zeroBudget = BurnRateEvaluation.unavailableWithObservedBadRatio(
                BigDecimal.ZERO, new BigDecimal("0.004"),
                BurnRateUnavailableReason.ZERO_ALLOWED_BAD_RATIO);

        assertThat(available.status()).isEqualTo(BurnRateStatus.AVAILABLE);
        assertThat(available.reason()).isNull();
        assertThat(zeroBudget.status()).isEqualTo(BurnRateStatus.UNAVAILABLE);
        assertThat(zeroBudget.burnRate()).isNull();
        assertThatThrownBy(() -> BurnRateEvaluation.available(
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> BurnRateEvaluation.unavailableWithObservedBadRatio(
                new BigDecimal("0.1"), new BigDecimal("0.2"), BurnRateUnavailableReason.NO_TRAFFIC))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void enforcesJsonSafeTargetsRatiosAndBurnRange() {
        ServiceIdentity service = new ServiceIdentity("checkout", "commerce", "production");

        assertThat(new SloDefinition(
                "safe", "Safe", null, service, SliType.ERROR_RATE,
                new BigDecimal("1E-308"), EvaluationWindow.PT5M, true).target())
                .isEqualByComparingTo("1E-308");
        assertThatThrownBy(() -> new SloDefinition(
                "unsafe", "Unsafe", null, service, SliType.ERROR_RATE,
                new BigDecimal("1E-309"), EvaluationWindow.PT5M, true))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("JavaScript-safe burn rate");
        assertThatThrownBy(() -> BurnRateEvaluation.available(
                new BigDecimal("0.001"), new BigDecimal("1E-400"), BigDecimal.ONE))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("JavaScript number");
        assertThatThrownBy(() -> BurnRateEvaluation.available(
                new BigDecimal("0.001"), BigDecimal.ONE, new BigDecimal("1E+309")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("JavaScript number");
    }
}
