package io.geordi.logs.domain;

public record ServiceIdentity(String name, String namespace, String environment) {

    public ServiceIdentity {
        name = requireText(name, "service name");
        namespace = normalize(namespace);
        environment = requireText(environment, "environment");
    }

    private static String requireText(String value, String description) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(description + " must not be blank");
        }
        return value.trim();
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
