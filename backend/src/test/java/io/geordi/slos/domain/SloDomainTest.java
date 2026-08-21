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
}
