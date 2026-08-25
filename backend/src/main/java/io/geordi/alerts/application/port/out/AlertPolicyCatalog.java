package io.geordi.alerts.application.port.out;

import io.geordi.alerts.domain.AlertPolicy;
import java.util.List;
import java.util.Optional;

public interface AlertPolicyCatalog {

    List<AlertPolicy> findAll();

    Optional<AlertPolicy> findById(String id);
}
