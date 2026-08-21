package io.geordi.slos.adapter.out.config;

import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.EvaluationWindow;
import io.geordi.slos.domain.ServiceIdentity;
import io.geordi.slos.domain.SliType;
import io.geordi.slos.domain.SloDefinition;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Comparator;

public final class ConfigurationSloDefinitionCatalog implements SloDefinitionCatalog {

    public static final int MAXIMUM_DEFINITIONS = 50;

    private final List<SloDefinition> definitions;
    private final Map<String, SloDefinition> byId;

    public ConfigurationSloDefinitionCatalog(SloDefinitionsProperties properties) {
        if (properties.definitions().size() > MAXIMUM_DEFINITIONS) {
            throw new IllegalArgumentException("SLO catalog must not exceed 50 definitions");
        }
        LinkedHashMap<String, SloDefinition> mapped = new LinkedHashMap<>();
        for (SloDefinitionsProperties.DefinitionSettings settings : properties.definitions()) {
            SloDefinition definition = map(settings);
            if (mapped.putIfAbsent(definition.id(), definition) != null) {
                throw new IllegalArgumentException("SLO catalog contains a duplicate id");
            }
        }
        byId = Map.copyOf(mapped);
        definitions = mapped.values().stream()
                .sorted(Comparator.comparing(SloDefinition::name).thenComparing(SloDefinition::id))
                .toList();
    }

    @Override
    public List<SloDefinition> findAll() {
        return definitions;
    }

    @Override
    public Optional<SloDefinition> findById(String id) {
        return Optional.ofNullable(byId.get(id));
    }

    private static SloDefinition map(SloDefinitionsProperties.DefinitionSettings settings) {
        if (settings == null || settings.service() == null) {
            throw new IllegalArgumentException("SLO definition and service must not be null");
        }
        return new SloDefinition(
                settings.id(), settings.name(), settings.description(),
                new ServiceIdentity(
                        settings.service().name(), settings.service().namespace(), settings.service().environment()),
                parseSliType(settings.sliType()), settings.target(), EvaluationWindow.from(settings.window()),
                settings.enabled() == null || settings.enabled());
    }

    private static SliType parseSliType(String value) {
        try {
            return SliType.valueOf(value);
        } catch (NullPointerException | IllegalArgumentException exception) {
            throw new IllegalArgumentException("unsupported SLI type", exception);
        }
    }
}
