package io.geordi.alerts.adapter.out.config;

import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertPolicy;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class ConfigurationAlertPolicyCatalog implements AlertPolicyCatalog {

    public static final int MAXIMUM_POLICIES = 50;

    private final List<AlertPolicy> policies;
    private final Map<String, AlertPolicy> byId;

    public ConfigurationAlertPolicyCatalog(AlertPoliciesProperties properties) {
        if (properties.policies().size() > MAXIMUM_POLICIES) {
            throw new IllegalArgumentException("alert policy catalog must not exceed 50 policies");
        }
        LinkedHashMap<String, AlertPolicy> mapped = new LinkedHashMap<>();
        for (AlertPoliciesProperties.PolicySettings settings : properties.policies()) {
            AlertPolicy policy = map(settings);
            if (mapped.putIfAbsent(policy.id(), policy) != null) {
                throw new IllegalArgumentException("alert policy catalog contains a duplicate id");
            }
        }
        byId = Map.copyOf(mapped);
        policies = mapped.values().stream()
                .sorted(Comparator.comparing(AlertPolicy::name).thenComparing(AlertPolicy::id))
                .toList();
    }

    @Override
    public List<AlertPolicy> findAll() {
        return policies;
    }

    @Override
    public Optional<AlertPolicy> findById(String id) {
        return Optional.ofNullable(byId.get(id));
    }

    private static AlertPolicy map(AlertPoliciesProperties.PolicySettings settings) {
        if (settings == null || settings.condition() == null) {
            throw new IllegalArgumentException("alert policy and condition must not be null");
        }
        return new AlertPolicy(
                settings.id(), settings.name(), settings.description(),
                settings.enabled() == null || settings.enabled(), settings.sloId(),
                new AlertCondition(parseType(settings.condition().type()), settings.condition().threshold()));
    }

    private static AlertConditionType parseType(String value) {
        try {
            return AlertConditionType.valueOf(value);
        } catch (NullPointerException | IllegalArgumentException exception) {
            throw new IllegalArgumentException("unsupported alert condition type", exception);
        }
    }
}
