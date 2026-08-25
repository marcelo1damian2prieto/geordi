package io.geordi.alerts.domain;

public record ServiceIdentity(String name, String namespace, String environment) {

    public ServiceIdentity {
        name = required(name, "service name");
        namespace = namespace == null || namespace.isBlank() ? null : namespace.trim();
        environment = required(environment, "environment");
    }

    private static String required(String value, String description) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
        return value.trim();
    }
}
