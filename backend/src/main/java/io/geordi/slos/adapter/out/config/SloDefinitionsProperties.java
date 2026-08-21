package io.geordi.slos.adapter.out.config;

import java.math.BigDecimal;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.slo", ignoreUnknownFields = false)
public record SloDefinitionsProperties(List<DefinitionSettings> definitions) {

    public SloDefinitionsProperties {
        definitions = definitions == null ? List.of() : List.copyOf(definitions);
    }

    public record DefinitionSettings(
            String id,
            String name,
            String description,
            ServiceSettings service,
            String sliType,
            BigDecimal target,
            String window,
            Boolean enabled) {
    }

    public record ServiceSettings(String name, String namespace, String environment) {
    }
}
