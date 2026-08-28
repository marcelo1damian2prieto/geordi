package io.geordi.alerts.application;

import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleBindingMismatchException;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Function;
import java.util.stream.Collectors;

public final class AlertLifecycleQueryService {

    private final AlertPolicyCatalog catalog;
    private final AlertLifecycleRepository repository;
    private final SloLifecycleBindingPort sloBindings;

    public AlertLifecycleQueryService(
            AlertPolicyCatalog catalog,
            AlertLifecycleRepository repository,
            SloLifecycleBindingPort sloBindings) {
        this.catalog = Objects.requireNonNull(catalog, "alert policy catalog must not be null");
        this.repository = Objects.requireNonNull(repository, "alert lifecycle repository must not be null");
        this.sloBindings = Objects.requireNonNull(sloBindings, "SLO lifecycle bindings must not be null");
    }

    public List<AlertLifecycleSnapshot> findAll() {
        Map<String, VersionedAlertLifecycle> stored = repository.findAll().stream()
                .collect(Collectors.toUnmodifiableMap(
                        item -> item.lifecycle().policyId(), Function.identity()));
        return catalog.findAll().stream()
                .map(policy -> new AlertLifecycleSnapshot(
                        policy,
                        stored.containsKey(policy.id()) ? stored.get(policy.id()).lifecycle() : null,
                        sloBindings.findById(policy.sloId())
                                .orElseThrow(AlertLifecycleBindingMismatchException::new)))
                .toList();
    }
}
