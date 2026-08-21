package io.geordi.slos.adapter.out.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class ConfigurationSloDefinitionCatalogTest {

    @Test
    void createsOneImmutableValidatedSnapshot() {
        SloDefinitionsProperties properties = new SloDefinitionsProperties(List.of(
                settings("zeta", "Zeta"), settings("alpha", "Alpha")));
        ConfigurationSloDefinitionCatalog catalog = new ConfigurationSloDefinitionCatalog(properties);

        assertThat(catalog.findById("zeta")).isPresent();
        assertThat(catalog.findAll()).extracting(io.geordi.slos.domain.SloDefinition::id)
                .containsExactly("alpha", "zeta");
        assertThatThrownBy(() -> catalog.findAll().clear()).isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void rejectsDuplicatesAndMoreThanFiftyDefinitionsAtomically() {
        assertThatThrownBy(() -> new ConfigurationSloDefinitionCatalog(
                new SloDefinitionsProperties(List.of(settings("same"), settings("same")))))
                .isInstanceOf(IllegalArgumentException.class);

        List<SloDefinitionsProperties.DefinitionSettings> tooMany = new ArrayList<>();
        for (int index = 0; index < 51; index++) {
            tooMany.add(settings("objective-" + index));
        }
        assertThatThrownBy(() -> new ConfigurationSloDefinitionCatalog(new SloDefinitionsProperties(tooMany)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static SloDefinitionsProperties.DefinitionSettings settings(String id) {
        return settings(id, "Availability");
    }

    private static SloDefinitionsProperties.DefinitionSettings settings(String id, String name) {
        return new SloDefinitionsProperties.DefinitionSettings(
                id, name, null,
                new SloDefinitionsProperties.ServiceSettings("checkout", "commerce", "production"),
                "AVAILABILITY", new BigDecimal("0.999"), "PT5M", true);
    }
}
