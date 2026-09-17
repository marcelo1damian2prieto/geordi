package io.geordi.alerts.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
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
            assertThat(policy.condition()).isInstanceOfSatisfying(
                    BurnRateAboveCondition.class,
                    condition -> assertThat(condition.threshold()).isEqualByComparingTo("2"));
        });
        assertThatThrownBy(() -> catalog.findAll().add(catalog.findAll().getFirst()))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void mapsOneOrTwoMultiwindowBandsInCanonicalOrder() {
        var settings = new AlertPoliciesProperties.PolicySettings(
                "policy", "Policy", null, true, "slo",
                new AlertPoliciesProperties.ConditionSettings(
                        "MULTIWINDOW_BURN_RATE",
                        null,
                        List.of(
                                new AlertPoliciesProperties.BandSettings("PT6H", "PT30M", new BigDecimal("6.00")),
                                new AlertPoliciesProperties.BandSettings("PT1H", "PT5M", new BigDecimal("14.4")))));

        var policy = new ConfigurationAlertPolicyCatalog(properties(settings)).findById("policy").orElseThrow();

        assertThat(policy.condition()).isInstanceOfSatisfying(MultiwindowBurnRateCondition.class, condition -> {
            assertThat(condition.bands()).extracting(band -> band.longWindow())
                    .containsExactly(AlertObservationWindow.PT1H, AlertObservationWindow.PT6H);
            assertThat(condition.bands()).extracting(band -> band.threshold())
                    .containsExactly(new BigDecimal("14.4"), new BigDecimal("6"));
        });
    }

    @Test
    void rejectsMixedMissingDuplicateUnsupportedAndOversizedConditionShapes() {
        AlertPoliciesProperties.BandSettings fast =
                new AlertPoliciesProperties.BandSettings("PT1H", "PT5M", new BigDecimal("14.4"));
        AlertPoliciesProperties.BandSettings slow =
                new AlertPoliciesProperties.BandSettings("PT6H", "PT30M", new BigDecimal("6"));

        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "BURN_RATE_ABOVE", BigDecimal.ONE, List.of(fast)));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "BURN_RATE_ABOVE", null, null));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", BigDecimal.ONE, List.of(fast)));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null, null));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null, List.of()));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null, List.of(fast, fast)));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null, List.of(fast, slow, fast)));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null,
                List.of(new AlertPoliciesProperties.BandSettings("PT1H", "PT30M", BigDecimal.ONE))));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null,
                List.of(new AlertPoliciesProperties.BandSettings("PT3D", "PT30M", BigDecimal.ONE))));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null,
                List.of(new AlertPoliciesProperties.BandSettings("PT1H", "PT5M", new BigDecimal("-1")))));
        assertInvalid(new AlertPoliciesProperties.ConditionSettings(
                "MULTIWINDOW_BURN_RATE", null,
                List.of(new AlertPoliciesProperties.BandSettings("PT1H", "PT5M", null))));
    }

    @Test
    void rejectsDuplicatesUnsupportedTypesAndOverflow() {
        assertThatThrownBy(() -> new ConfigurationAlertPolicyCatalog(properties(
                settings("same", "One", true, null), settings("same", "Two", true, null))))
                .isInstanceOf(IllegalArgumentException.class);

        var unsupported = new AlertPoliciesProperties.PolicySettings(
                "policy", "Policy", null, true, "slo", new AlertPoliciesProperties.ConditionSettings(
                        "GENERIC_EXPRESSION", BigDecimal.ONE, null));
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
                        "BURN_RATE_ABOVE", threshold == null ? new BigDecimal("2") : threshold, null));
    }

    private static void assertInvalid(AlertPoliciesProperties.ConditionSettings condition) {
        var settings = new AlertPoliciesProperties.PolicySettings(
                "policy", "Policy", null, true, "slo", condition);
        assertThatThrownBy(() -> new ConfigurationAlertPolicyCatalog(properties(settings)))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
