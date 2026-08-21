package io.geordi.slos.domain;

public record ServiceIdentity(String name, String namespace, String environment) {

    public ServiceIdentity {
        name = required(name, "service name");
        namespace = optional(namespace);
        environment = required(environment, "environment");
    }

    private static String required(String value, String description) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
        return value.trim();
    }

    private static String optional(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
