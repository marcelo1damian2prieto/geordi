package io.geordi.metrics.domain;

public record ServiceIdentity(String name, String namespace, String environment) {

    public ServiceIdentity {
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("service name must not be blank");
        }
        if (environment == null || environment.isBlank()) {
            throw new IllegalArgumentException("environment must not be blank");
        }
        name = name.trim();
        namespace = normalize(namespace);
        environment = environment.trim();
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
