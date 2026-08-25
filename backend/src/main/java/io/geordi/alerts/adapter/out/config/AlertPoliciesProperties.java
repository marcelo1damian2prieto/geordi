package io.geordi.alerts.adapter.out.config;

import java.math.BigDecimal;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.alert", ignoreUnknownFields = false)
public record AlertPoliciesProperties(List<PolicySettings> policies) {

    public AlertPoliciesProperties {
        policies = policies == null ? List.of() : List.copyOf(policies);
    }

    public record PolicySettings(
            String id,
            String name,
            String description,
            Boolean enabled,
            String sloId,
            ConditionSettings condition) {
    }

    public record ConditionSettings(String type, BigDecimal threshold) {
    }
}
