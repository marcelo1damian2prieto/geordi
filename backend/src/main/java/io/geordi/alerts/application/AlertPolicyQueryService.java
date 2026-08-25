package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertPolicy;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public final class AlertPolicyQueryService {

    private final AlertPolicyCatalog catalog;

    public AlertPolicyQueryService(AlertPolicyCatalog catalog) {
        this.catalog = Objects.requireNonNull(catalog, "alert policy catalog must not be null");
    }

    public List<AlertPolicy> findAll() {
        return catalog.findAll().stream()
                .sorted(Comparator.comparing(AlertPolicy::name).thenComparing(AlertPolicy::id))
                .toList();
    }
}
