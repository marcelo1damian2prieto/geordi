package io.geordi.slos.application.port.out;

import io.geordi.slos.domain.SloDefinition;
import java.util.List;
import java.util.Optional;

public interface SloDefinitionCatalog {

    List<SloDefinition> findAll();

    Optional<SloDefinition> findById(String id);
}
