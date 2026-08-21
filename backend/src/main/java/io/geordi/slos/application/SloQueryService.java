package io.geordi.slos.application;

import io.geordi.slos.application.port.out.SloDefinitionCatalog;
import io.geordi.slos.domain.SloDefinition;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public final class SloQueryService {

    private final SloDefinitionCatalog catalog;

    public SloQueryService(SloDefinitionCatalog catalog) {
        this.catalog = Objects.requireNonNull(catalog, "SLO catalog must not be null");
    }

    public List<SloDefinition> findAll() {
        return catalog.findAll().stream()
                .sorted(Comparator.comparing(SloDefinition::name).thenComparing(SloDefinition::id))
                .toList();
    }

    public SloDefinition findById(String id) {
        if (id == null || id.isBlank()) {
            throw new IllegalArgumentException("SLO id must not be blank");
        }
        return catalog.findById(id).orElseThrow(SloNotFoundException::new);
    }
}
