package io.geordi.alerts.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class ConfigurationAlertPolicyCatalogTest {

    @Test
    void mapsDefaultsAndSortsOneImmutableSnapshot() {
        var catalog = new ConfigurationAlertPolicyCatalog(properties(
                settings("z-policy", "Zulu", null, null),
                settings("a-policy", "Alpha", false, new BigDecimal("0"))));

        assertThat(catalog.findAll()).extracting(policy -> policy.id())
                .containsExactly("a-policy", "z-policy");
        assertThat(catalog.findById("z-policy")).get().satisfies(policy -> {
            assertThat(policy.enabled()).isTrue();
            assertThat(policy.condition().threshold()).isEqualByComparingTo("2");
        });
        assertThatThrownBy(() -> catalog.findAll().add(catalog.findAll().getFirst()))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void rejectsDuplicatesUnsupportedTypesAndOverflow() {
        assertThatThrownBy(() -> new ConfigurationAlertPolicyCatalog(properties(
                settings("same", "One", true, null), settings("same", "Two", true, null))))
                .isInstanceOf(IllegalArgumentException.class);

        var unsupported = new AlertPoliciesProperties.PolicySettings(
                "policy", "Policy", null, true, "slo", new AlertPoliciesProperties.ConditionSettings(
                        "GENERIC_EXPRESSION", BigDecimal.ONE));
        assertThatThrownBy(() -> new ConfigurationAlertPolicyCatalog(properties(unsupported)))
                .isInstanceOf(IllegalArgumentException.class);

        List<AlertPoliciesProperties.PolicySettings> tooMany = new ArrayList<>();
        for (int index = 0; index <= ConfigurationAlertPolicyCatalog.MAXIMUM_POLICIES; index++) {
            tooMany.add(settings("policy-" + index, "Policy " + index, true, null));
        }
        assertThatThrownBy(() -> new ConfigurationAlertPolicyCatalog(new AlertPoliciesProperties(tooMany)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static AlertPoliciesProperties properties(AlertPoliciesProperties.PolicySettings... settings) {
        return new AlertPoliciesProperties(List.of(settings));
    }

    private static AlertPoliciesProperties.PolicySettings settings(
            String id, String name, Boolean enabled, BigDecimal threshold) {
        return new AlertPoliciesProperties.PolicySettings(
                id, name, null, enabled, "checkout-availability",
                new AlertPoliciesProperties.ConditionSettings(
                        "BURN_RATE_ABOVE", threshold == null ? new BigDecimal("2") : threshold));
    }
}
