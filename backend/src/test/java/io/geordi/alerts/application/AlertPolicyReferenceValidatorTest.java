package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertPolicy;
import java.math.BigDecimal;
import java.util.List;
import org.junit.jupiter.api.Test;

class AlertPolicyReferenceValidatorTest {

    @Test
    void validatesAllReferencesIncludingDisabledPolicies() {
        AlertPolicy enabled = policy("enabled", true, "known");
        AlertPolicy disabled = policy("disabled", false, "known");

        assertThatCode(() -> new AlertPolicyReferenceValidator("known"::equals)
                .validate(List.of(enabled, disabled))).doesNotThrowAnyException();
        assertThatThrownBy(() -> new AlertPolicyReferenceValidator("known"::equals)
                .validate(List.of(policy("disabled", false, "missing"))))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("disabled");
    }

    private static AlertPolicy policy(String id, boolean enabled, String sloId) {
        return new AlertPolicy(
                id, "Policy " + id, null, enabled, sloId,
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE));
    }
}
