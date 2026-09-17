package io.geordi.alerts.adapter.out.config;

import java.util.Objects;
import java.util.regex.Pattern;
import org.springframework.boot.context.properties.source.ConfigurationPropertyName;
import org.springframework.boot.context.properties.source.ConfigurationPropertySource;
import org.springframework.boot.context.properties.source.ConfigurationPropertySources;
import org.springframework.boot.context.properties.source.IterableConfigurationPropertySource;
import org.springframework.core.env.ConfigurableEnvironment;

public final class AlertPolicyConfigurationFields {

    private static final ConfigurationPropertyName POLICIES = ConfigurationPropertyName.of("geordi.alert.policies");
    private static final Pattern ALLOWED_FIELD = Pattern.compile(
            "geordi\\.alert\\.policies(?:\\[\\d+\\](?:\\."
                    + "(?:id|name|description|enabled|slo-?id|condition|"
                    + "condition\\.(?:type|threshold|bands(?:\\[\\d+\\](?:\\."
                    + "(?:long-?window|short-?window|threshold))?)?)))?)?");

    private AlertPolicyConfigurationFields() {
    }

    public static void rejectUnknownFields(ConfigurableEnvironment environment) {
        Objects.requireNonNull(environment, "alert policy configuration environment must not be null");
        for (ConfigurationPropertySource source : ConfigurationPropertySources.get(environment)) {
            if (source instanceof IterableConfigurationPropertySource iterable) {
                for (ConfigurationPropertyName name : iterable) {
                    if ((POLICIES.equals(name) || POLICIES.isAncestorOf(name))
                            && !ALLOWED_FIELD.matcher(name.toString()).matches()) {
                        throw new IllegalArgumentException("unsupported alert policy configuration field");
                    }
                }
            }
        }
    }
}
